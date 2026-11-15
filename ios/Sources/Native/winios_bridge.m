/* SPDX-License-Identifier: GPL-2.0-or-later */
#import "winios_bridge.h"

#include "hvsparse.h"
#include "share.h"
#include "winios_jit.h"
#include "winvm.h"
#include <TargetConditionals.h>
#include <fcntl.h>
#include <unistd.h>

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <sys/stat.h>
#include <sys/utsname.h>

static WinIOSBridge *s_shared_bridge = nil;

@interface WinIOSBridge () {
    BOOL _vmRunning;
    BOOL _unpacking;
    double _unpackProgress;
    NSString *_vmStatus;
    dispatch_queue_t _diagQueue;
    dispatch_source_t _diagTimer;
    CFAbsoluteTime _bootStartTime;
    uint64_t _configuredRamMB;
    int _configuredCPUs;
    NSString *_selectedMachineDirectory;
    uint64_t _requestedRamMB;
    int _requestedCPUs;
    BOOL _networkEnabled;
    BOOL _audioEnabled;
    BOOL _hasCreatedVM;
    NSString *_deletingMachineDirectory;
    BOOL _primaryDiskReadOnly;
    BOOL _sharedFolderEnabled;
    BOOL _microphoneEnabled;
    BOOL _diagnosticLogging;
    int _displayRefreshRate;
    int _tcpForwardHostPort;
    int _tcpForwardGuestPort;
    CAMetalLayer *__weak _pendingLayer;
    uint64_t _diagTickCount;
    uint64_t _lastMachTicks;
    uint64_t _lastWfiTicks;
    double _lastWfiIdlePct;

    os_unfair_lock _metricsLock;
    CGSize _screenSizePts;
    CGFloat _screenScale;
    NSInteger _hingeStatus;
    double _hingeAngleDegrees;
}
- (void)handleVMExitWithReason:(NSString *)reason;
- (void)updateUnpackProgress:(double)frac;
- (void)startDiagTimer;
- (void)stopDiagTimer;
@end

static void vm_exit_trampoline(int reason) {
    NSString *r = [NSString stringWithUTF8String:hv_winvm_reason_name(reason)];
    dispatch_async(dispatch_get_main_queue(), ^{
        [s_shared_bridge handleVMExitWithReason:r];
    });
}

typedef struct UnpackCtx {
    __unsafe_unretained WinIOSBridge *bridge;
    CFAbsoluteTime lastUpdate;
} UnpackCtx;

static void unpack_progress_cb(uint64_t done, uint64_t total, void *opaque) {
    UnpackCtx *ctx = (UnpackCtx *)opaque;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (done < total && now - ctx->lastUpdate < 0.2) return;
    ctx->lastUpdate = now;
    double frac = total ? (double)done / (double)total : 0.0;
    WinIOSBridge *b = ctx->bridge;
    dispatch_async(dispatch_get_main_queue(), ^{
        [b updateUnpackProgress:frac];
    });
}

@implementation WinIOSBridge

+ (WinIOSBridge *)shared {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_shared_bridge = [[WinIOSBridge alloc] init];
    });
    return s_shared_bridge;
}

- (instancetype)init {
    if ((self = [super init])) {
        _vmStatus = @"Idle";
        _requestedRamMB = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 4096 : 4608;
        _requestedCPUs = 4;
        _networkEnabled = YES;
        _audioEnabled = YES;
        _sharedFolderEnabled = YES;
        _microphoneEnabled = UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad;
        _displayRefreshRate = 60;
        _metricsLock = OS_UNFAIR_LOCK_INIT;
        _screenSizePts = CGSizeZero;
        _screenScale = 3.0;
        _hingeStatus = 0;
        _hingeAngleDegrees = -1.0;
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        BOOL safariDefault = ([ud objectForKey:@"winios.safariOAuthV2"] == nil) ? YES : [ud boolForKey:@"winios.safariOAuthV2"];
        hv_share_set_url_handler_enabled(safariDefault ? 1 : 0);
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _diagQueue = dispatch_queue_create("me.ammaar.windowsios.diag", attr);
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(onAppBackgroundOrTerminate:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(onAppBackgroundOrTerminate:) name:UIApplicationWillTerminateNotification object:nil];
        [nc addObserver:self selector:@selector(onAudioInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
    }
    return self;
}

- (void)configureAudioSessionAndMicPermission {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (!_microphoneEnabled) {
        [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [session setActive:YES error:nil];
        return;
    }
    AVAudioSessionCategoryOptions opts = AVAudioSessionCategoryOptionDefaultToSpeaker |
                                         AVAudioSessionCategoryOptionAllowBluetooth |
                                         AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                         AVAudioSessionCategoryOptionMixWithOthers;
    NSError *err = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:opts error:&err]) {
        /* Fallback to Playback if PlayAndRecord temporarily rejected before permission */
        [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    }
    [session setPreferredSampleRate:48000.0 error:nil];
    [session setPreferredIOBufferDuration:0.010 error:nil];
    [session setActive:YES error:nil];

    if (@available(iOS 17.0, *)) {
        [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL granted) {
            if (granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    AVAudioSession *s = [AVAudioSession sharedInstance];
                    [s setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:opts error:nil];
                    [s setActive:YES error:nil];
                });
            }
        }];
    }
}

- (void)onAudioInterruption:(NSNotification *)note {
    NSNumber *typeNum = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (typeNum && typeNum.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
    }
}

- (void)onAppBackgroundOrTerminate:(NSNotification *)note {
    (void)note;
    if (_vmRunning) {
        dispatch_async(_diagQueue, ^{
            hv_winvm_flush_disks();
        });
    }
}

- (void)notifyChanged {
    if ([NSThread isMainThread]) {
        if (self.onStateChanged) self.onStateChanged();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onStateChanged) self.onStateChanged();
        });
    }
}

- (void)updateScreenSize:(CGSize)size scale:(CGFloat)scale {
    os_unfair_lock_lock(&_metricsLock);
    _screenSizePts = size;
    if (scale > 0.0) _screenScale = scale;
    os_unfair_lock_unlock(&_metricsLock);
}

- (void)updateHingeStatus:(NSInteger)status angleDegrees:(double)angleDegrees {
    os_unfair_lock_lock(&_metricsLock);
    _hingeStatus = status;
    _hingeAngleDegrees = angleDegrees;
    os_unfair_lock_unlock(&_metricsLock);
}

- (void)installTrapGuard {
    winios_jit_install_trap_handler();
    UIScreen *mainScreen = [UIScreen mainScreen];
    [self updateScreenSize:mainScreen.bounds.size scale:mainScreen.scale];
    [self notifyChanged];
}

- (BOOL)tryAcquireJIT:(BOOL)detachAfter {
    winios_jit_set_guest_memory_mb(_requestedRamMB);
    BOOL ok = winios_jit_acquire(WINIOS_JIT_DEFAULT_BYTES, detachAfter);
    dispatch_async(_diagQueue, ^{
        [self writeDiagnosticsSnapshot];
    });
    [self notifyChanged];
    return ok;
}

- (BOOL)isJITLive {
    return winios_jit_is_live();
}

- (BOOL)isDebuggerAttached {
    return winios_jit_is_debugger_attached();
}

- (uint64_t)jitHelperTokenAddress {
    return winios_jit_helper_token_address();
}

- (BOOL)canDeleteMachineDirectory:(NSString *)directory {
    if (_deletingMachineDirectory) return NO;
    NSString *canonical = directory.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString *machines = [[[self documentsPath] stringByAppendingPathComponent:@"Machines"] stringByResolvingSymlinksInPath];
    if (![[canonical stringByDeletingLastPathComponent] isEqualToString:machines]) return NO;
    if (_unpacking) return NO;
    /* Stopped/failed engines still retain process-global mappings and open
     * disk handles. Permit other machines, but protect the retained directory
     * until process relaunch supplies a real lifetime boundary. */
    if (_hasCreatedVM || _vmRunning) {
        NSString *owned = [self machineDirectory].stringByStandardizingPath.stringByResolvingSymlinksInPath;
        if ([canonical isEqualToString:owned]) return NO;
    }
    return YES;
}

- (BOOL)beginDeletingMachineDirectory:(NSString *)directory {
    if (![self canDeleteMachineDirectory:directory]) return NO;
    _deletingMachineDirectory = directory.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    [self notifyChanged];
    return YES;
}

- (void)finishDeletingMachineDirectory:(NSString *)directory {
    NSString *canonical = directory.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    if ([_deletingMachineDirectory isEqualToString:canonical]) {
        _deletingMachineDirectory = nil;
        [self notifyChanged];
    }
}

- (BOOL)isVMRunning {
    return _vmRunning;
}

- (BOOL)isUnpacking {
    return _unpacking;
}

- (double)unpackProgress {
    return _unpackProgress;
}

- (NSString *)jitStatusText {
    return [NSString stringWithUTF8String:winios_jit_status_text()];
}

- (NSString *)vmStatusText {
    return _vmStatus;
}

- (uint32_t)framebufferWidth {
    uint32_t w = 0, h = 0;
    if (_vmRunning && hv_winvm_display_size(&w, &h) == 0) return w;
    return 0;
}

- (uint32_t)framebufferHeight {
    uint32_t w = 0, h = 0;
    if (_vmRunning && hv_winvm_display_size(&w, &h) == 0) return h;
    return 0;
}

- (uint64_t)presentedFrames {
    return _vmRunning ? hv_winvm_display_frames() : 0;
}

- (uint64_t)availableMemoryMB {
    return (uint64_t)(winios_available_memory_bytes() >> 20);
}

- (uint64_t)maxGuestMemoryMB {
    /* Conservative admission policy, not a guarantee against Jetsam. Leave
     * physical headroom for iPadOS, dual JIT mappings, translation tables and UI. */
    uint64_t physicalMB = NSProcessInfo.processInfo.physicalMemory >> 20;
    uint64_t maximum = physicalMB > 3072 ? ((physicalMB - 3072) & ~255ull) : 0;
    return MIN(maximum, 4608ull);
}

- (NSString *)runtimeCapabilityText {
#if TARGET_OS_SIMULATOR
    return @"The ARM64 JIT engine requires a physical device.";
#else
    struct utsname info;
    uname(&info);
    BOOL duo = strcmp(info.machine, "iPhone19,4") == 0;
    BOOL ipad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    if (!duo && !ipad) return @"This build targets iPad and iPhone Duo only.";
    if (self.maxGuestMemoryMB < 4096) return @"Windows 11 requires 4 GiB guest RAM; this device lacks the configured host headroom.";
    return ipad ? @"Experimental iPad candidate. Debugger-assisted JIT and Windows boot require device verification."
                : @"iPhone Duo runtime. Debugger-assisted JIT is required.";
#endif
}

- (NSString *)networkStatusText {
    if (!_networkEnabled) return @"Disabled";
    if (!_vmRunning) return @"Not started";
    return hv_winvm_network_up() ? @"NAT backend ready (guest NetKVM driver required)" : @"NAT backend unavailable; check configured host port and diagnostics";
}

- (BOOL)configureRuntimeOptions:(NSDictionary<NSString *, NSNumber *> *)options {
    if (_vmRunning || _unpacking || _hasCreatedVM) return NO;
    for (id value in options.allValues) if (![value isKindOfClass:NSNumber.class]) return NO;
    NSInteger hz = options[@"displayRefreshRate"] ? options[@"displayRefreshRate"].integerValue : 60;
    NSInteger hp = options[@"tcpForwardHostPort"].integerValue;
    NSInteger gp = options[@"tcpForwardGuestPort"].integerValue;
    if ((hz != 30 && hz != 60 && hz != 120) ||
        ((hp || gp) && (hp < 1024 || hp > 65535 || gp < 1 || gp > 65535))) {
        _vmStatus = @"Choose 30/60/120 Hz and a TCP host port from 1024–65535 with a guest port from 1–65535, or set both ports to zero.";
        [self notifyChanged];
        return NO;
    }
    _primaryDiskReadOnly = options[@"primaryDiskReadOnly"].boolValue;
    _sharedFolderEnabled = options[@"sharedFolderEnabled"] ? options[@"sharedFolderEnabled"].boolValue : YES;
    _microphoneEnabled = options[@"microphoneEnabled"].boolValue;
    _diagnosticLogging = options[@"diagnosticLogging"].boolValue;
    _displayRefreshRate = (int)hz;
    _tcpForwardHostPort = (int)hp;
    _tcpForwardGuestPort = (int)gp;
    return YES;
}

- (BOOL)configureMachineDirectory:(NSString *)directory memoryMB:(uint64_t)memoryMB cpuCount:(NSInteger)cpuCount networkEnabled:(BOOL)networkEnabled audioEnabled:(BOOL)audioEnabled {
    if (_deletingMachineDirectory) {
        _vmStatus = @"Wait for virtual machine deletion to finish before starting a session.";
        [self notifyChanged];
        return NO;
    }
    if (_vmRunning || _unpacking || _hasCreatedVM) {
        _vmStatus = @"Close and relaunch the app before changing machines after a VM session.";
        [self notifyChanged];
        return NO;
    }
    NSString *resolved = directory.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString *machines = [[[self documentsPath] stringByAppendingPathComponent:@"Machines"] stringByResolvingSymlinksInPath];
    if (![resolved hasPrefix:[machines stringByAppendingString:@"/"]]) {
        _vmStatus = @"Machine files must be imported into Documents/Machines.";
        [self notifyChanged];
        return NO;
    }
    if (memoryMB < 4096 || memoryMB > self.maxGuestMemoryMB || (memoryMB % 256) != 0 || cpuCount < 1 || cpuCount > 4) {
        _vmStatus = @"Invalid configuration: choose 1–4 CPUs and 4–4.5 GiB RAM within this device's limit.";
        [self notifyChanged];
        return NO;
    }
    _selectedMachineDirectory = resolved;
    _requestedRamMB = memoryMB;
    _requestedCPUs = (int)cpuCount;
    _networkEnabled = networkEnabled;
    _audioEnabled = audioEnabled;
    winios_jit_set_guest_memory_mb(memoryMB);
    _vmStatus = @"Ready to start Windows 11 24H2 ARM64";
    [self notifyChanged];
    return YES;
}

- (BOOL)usbKeyboardReady {
    if (!_vmRunning) return NO;
    int kr = 0;
    hv_winvm_usb_stats(&kr, NULL, NULL);
    return kr != 0;
}

- (BOOL)usbTabletReady {
    if (!_vmRunning) return NO;
    int tr = 0;
    hv_winvm_usb_stats(NULL, &tr, NULL);
    return tr != 0;
}

- (uint64_t)usbEventsDelivered {
    if (!_vmRunning) return 0;
    uint64_t d = 0;
    hv_winvm_usb_stats(NULL, NULL, &d);
    return d;
}

- (NSString *)documentsPath {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
}

- (NSString *)machineDirectory {
    if (_selectedMachineDirectory) return _selectedMachineDirectory;
    NSString *docs = [self documentsPath];
    NSString *win11Dir = [docs stringByAppendingPathComponent:@"Machines/Win11"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:[win11Dir stringByAppendingPathComponent:@"code.fd"]]) {
        return win11Dir;
    }
    if ([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"code.fd"]]) {
        return docs;
    }
    [fm createDirectoryAtPath:win11Dir withIntermediateDirectories:YES attributes:nil error:nil];
    return win11Dir;
}

- (BOOL)hasRawDiskImageAt:(NSString *)dir {
    NSString *raw = [dir stringByAppendingPathComponent:@"windows11.img"];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:raw error:nil];
    return attrs && [attrs fileSize] >= (64ull << 20);
}

- (NSString *)firmwarePathForDirectory:(NSString *)directory {
    NSString *legacy = [directory stringByAppendingPathComponent:@"code.fd"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:legacy]) return legacy;
    return [NSBundle.mainBundle pathForResource:@"code" ofType:@"fd" inDirectory:@"Firmware"];
}

- (BOOL)shouldAttachAutomaticAnswersInDirectory:(NSString *)directory {
    NSString *markerPath = [directory stringByAppendingPathComponent:@"installation-created.json"];
    NSData *markerData = [NSData dataWithContentsOfFile:markerPath];
    NSDictionary *marker = markerData ? [NSJSONSerialization JSONObjectWithData:markerData options:0 error:nil] : nil;
    if (![marker isKindOfClass:NSDictionary.class] || ![marker[@"target"] isEqual:@"windows11.img"] ||
        ![marker[@"diskSizeGiB"] isKindOfClass:NSNumber.class]) return NO;
    uint64_t capacity = [marker[@"diskSizeGiB"] unsignedLongLongValue];
    if (capacity < 64 || capacity > 512) return NO;
    NSString *disk = [directory stringByAppendingPathComponent:@"windows11.img"];
    int fd = open(disk.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return NO;
    struct stat st;
    BOOL blank = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && (uint64_t)st.st_size == (capacity << 30);
    /* Never present the formatting answer to a partitioned or previously used
     * VM. Only the freshly created, app-marked sparse target qualifies. */
    uint8_t buffer[65536];
    for (int end = 0; end < 2 && blank; end++) {
        uint64_t base = end ? (uint64_t)st.st_size - (1u << 20) : 0;
        for (uint64_t offset = 0; offset < (1u << 20) && blank; offset += sizeof buffer) {
            if (pread(fd, buffer, sizeof buffer, (off_t)(base + offset)) != sizeof buffer) { blank = NO; break; }
            for (size_t i = 0; i < sizeof buffer; i++) if (buffer[i]) { blank = NO; break; }
        }
    }
    close(fd);
    return blank;
}

- (BOOL)needsSparseUnpack {
    NSString *dir = [self machineDirectory];
    /* An existing writable image always wins; never replace a user's disk. */
    if ([[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:@"windows11.img"]]) return NO;
    NSString *sparse = [dir stringByAppendingPathComponent:@"windows11.hvsparse"];
    return [[NSFileManager defaultManager] fileExistsAtPath:sparse];
}

- (BOOL)hasProvisionedMachine {
    NSString *dir = [self machineDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![self firmwarePathForDirectory:dir]) return NO;
    if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"vars.fd"]]) return NO;
    return [self hasRawDiskImageAt:dir] || [self needsSparseUnpack];
}

- (void)updateUnpackProgress:(double)frac {
    _unpackProgress = frac;
    _vmStatus = [NSString stringWithFormat:@"Unpacking Windows 11 NVMe image (%.0f%%)...", frac * 100.0];
    dispatch_async(_diagQueue, ^{
        [self writeDiagnosticsSnapshot];
    });
    [self notifyChanged];
}

- (void)bindMetalLayer:(nullable CAMetalLayer *)layer {
    _pendingLayer = layer;
    if (_vmRunning) {
        hv_winvm_set_display_layer((__bridge void *)layer);
    }
}

- (void)prepareAndStartWithLayer:(nullable CAMetalLayer *)layer {
    if (layer) _pendingLayer = layer;
    if (_vmRunning || _unpacking) return;
    if (_deletingMachineDirectory) {
        _vmStatus = @"Wait for virtual machine deletion to finish before starting a session.";
        [self notifyChanged];
        return;
    }
    if (_hasCreatedVM) {
        _vmStatus = @"Relaunch the app before starting another session; complete runtime teardown is not implemented.";
        [self notifyChanged];
        return;
    }
#if TARGET_OS_SIMULATOR
    _vmStatus = self.runtimeCapabilityText;
    [self notifyChanged];
    return;
#else
    struct utsname deviceInfo;
    uname(&deviceInfo);
    if ((UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad && strcmp(deviceInfo.machine, "iPhone19,4") != 0) || self.maxGuestMemoryMB < 4096) {
        _vmStatus = self.runtimeCapabilityText;
        [self notifyChanged];
        return;
    }
#endif

    if (!self.isJITLive) {
        [self tryAcquireJIT:YES];
        if (!self.isJITLive) {
            _vmStatus = @"JIT setup required. Use the device JIT helper or Enable JIT; Xcode Run alone is insufficient.";
            dispatch_async(_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
            [self notifyChanged];
            return;
        }
    }

    if (![self hasProvisionedMachine]) {
        _vmStatus = @"Create a machine from a Windows 11 ARM64 ISO in the library. Firmware and the writable disk are prepared by the app.";
        dispatch_async(_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
        [self notifyChanged];
        return;
    }

    NSString *dir = [self machineDirectory];
    if ([self needsSparseUnpack]) {
        _unpacking = YES;
        _unpackProgress = 0.0;
        _vmStatus = @"Unpacking Windows 11 NVMe image (0%)...";
        dispatch_async(_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
        [self notifyChanged];

        NSString *src = [dir stringByAppendingPathComponent:@"windows11.hvsparse"];
        NSString *dst = [dir stringByAppendingPathComponent:@"windows11.img"];
        NSString *tmpDst = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.unpacking", NSUUID.UUID.UUIDString]];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UnpackCtx ctx = {.bridge = self, .lastUpdate = 0};
            int rc = hv_sparse_unpack(src.fileSystemRepresentation, tmpDst.fileSystemRepresentation, unpack_progress_cb, &ctx);
            /* link() atomically publishes only when destination does not exist.
             * Keep the source sparse image for recovery and future re-import. */
            if (rc == 0) {
                int fd = open(tmpDst.fileSystemRepresentation, O_RDWR);
                if (fd < 0) rc = -1;
                else { if (fsync(fd) != 0) rc = -1; close(fd); }
                if (rc == 0 && link(tmpDst.fileSystemRepresentation, dst.fileSystemRepresentation) != 0) rc = -1;
            }
            unlink(tmpDst.fileSystemRepresentation);
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_unpacking = NO;
                if (rc == 0) {
                    self->_unpackProgress = 1.0;
                    [self startConfiguredVMInDirectory:dir];
                } else {
                    self->_vmStatus = @"Image extraction failed (check free storage). Existing disks and the source were preserved.";
                    dispatch_async(self->_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
                    [self notifyChanged];
                }
            });
        });
        return;
    }

    [self startConfiguredVMInDirectory:dir];
}

- (void)startConfiguredVMInDirectory:(NSString *)dir {
    if (_vmRunning) return;
    if (_audioEnabled) [self configureAudioSessionAndMicPermission];

    WinIosDualMapping jit = winios_jit_mapping();
    if (!jit.rx_addr || !jit.rw_addr) {
        _vmStatus = @"Error: JIT region missing";
        [self notifyChanged];
        return;
    }

    NSString *ramBacking = [NSTemporaryDirectory() stringByAppendingPathComponent:@"win11_guest_ram.bin"];
    setenv("HV_RAM_FILE", ramBacking.fileSystemRepresentation, 1);

    uint64_t preallocBytes = 0;
    void *preallocRam = winios_jit_guest_ram(&preallocBytes);
    uint64_t ramMB = MIN(_requestedRamMB, self.maxGuestMemoryMB);
    if (ramMB < 4096 || (preallocRam && preallocBytes < (ramMB << 20)) ||
        (!preallocRam && [self availableMemoryMB] < ramMB + 1024)) {
        _vmStatus = @"Insufficient guest RAM reservation. Relaunch with the selected memory setting and attach the JIT helper; no unsafe low-memory fallback was used.";
        [self notifyChanged];
        return;
    }

    NSString *sharedDir = [[self documentsPath] stringByAppendingPathComponent:@"Shared"];
    [[NSFileManager defaultManager] createDirectoryAtPath:sharedDir withIntermediateDirectories:YES attributes:nil error:nil];
    /* Keep AF_UNIX sun_path well under Darwin's 104-byte limit (~82 bytes vs 106 bytes) */
    NSString *rawTmp = [NSTemporaryDirectory() stringByReplacingOccurrencesOfString:@"/private/var/" withString:@"/var/"];
    NSString *shareSock = [rawTmp stringByAppendingPathComponent:@"s"];
    unlink(shareSock.fileSystemRepresentation);

    NSString *codePath = [self firmwarePathForDirectory:dir];
    NSString *varsPath = [dir stringByAppendingPathComponent:@"vars.fd"];
    NSString *diskPath = [dir stringByAppendingPathComponent:@"windows11.img"];
    NSString *secondaryDisk = [dir stringByAppendingPathComponent:@"secondary.img"];
    BOOL hasSecondaryDisk = [[NSFileManager defaultManager] fileExistsAtPath:secondaryDisk];
    NSString *installerISO = [dir stringByAppendingPathComponent:@"installer.iso"];
    BOOL hasInstallerISO = [[NSFileManager defaultManager] fileExistsAtPath:installerISO];
    NSString *answerDisk = [dir stringByAppendingPathComponent:@"setup-support.img"];
    BOOL attachAnswers = hasInstallerISO && !hasSecondaryDisk && !_primaryDiskReadOnly &&
        [self shouldAttachAutomaticAnswersInDirectory:dir] && [[NSFileManager defaultManager] fileExistsAtPath:answerDisk];

    _configuredRamMB = ramMB;
    _configuredCPUs = _requestedCPUs;

    HvWinVmConfig cfg = {
        .code_fd = codePath.fileSystemRepresentation,
        .vars_fd = varsPath.fileSystemRepresentation,
        .disk0 = diskPath.fileSystemRepresentation,
        .disk1 = hasSecondaryDisk ? secondaryDisk.fileSystemRepresentation : NULL,
        .share_dir = _sharedFolderEnabled && _networkEnabled ? sharedDir.fileSystemRepresentation : NULL,
        .share_sock = _sharedFolderEnabled && _networkEnabled ? shareSock.fileSystemRepresentation : NULL,
        .ncpus = _configuredCPUs,
        .ram_mb = _configuredRamMB,
        .jit_bytes = jit.size,
        .jit_rx = jit.rx_addr,
        .jit_rw = jit.rw_addr,
        .prealloc_ram = preallocRam,
        .no_net = _networkEnabled ? 0 : 1,
        .enable_sound = _audioEnabled ? 1 : 0,
        .log = _diagnosticLogging ? 1 : 0,
        .stats_interval = 0,
        .disk0_readonly = _primaryDiskReadOnly,
        .disable_microphone = !_microphoneEnabled,
        .display_refresh_hz = _displayRefreshRate,
        .tcp_forward_host_port = _tcpForwardHostPort,
        .tcp_forward_guest_port = _tcpForwardGuestPort,
        .installer_iso = hasInstallerISO ? installerISO.fileSystemRepresentation : NULL,
        .installer_answer_disk = attachAnswers ? answerDisk.fileSystemRepresentation : NULL,
    };

    char err[256] = {0};
    /* The current engine owns process-global state and has no complete destroy
     * path. Do not recreate it over live threads, mappings or disk handles. */
    _hasCreatedVM = YES;
    if (hv_winvm_create(&cfg, err, sizeof err) != 0) {
        _vmStatus = [NSString stringWithFormat:@"VM create failed: %s", err];
        dispatch_async(_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
        [self notifyChanged];
        return;
    }

    CAMetalLayer *layer = _pendingLayer;
    if (layer) {
        hv_winvm_set_display_layer((__bridge void *)layer);
    }

    _vmRunning = YES;
    _bootStartTime = CFAbsoluteTimeGetCurrent();
    _diagTickCount = 0;
    _lastMachTicks = mach_absolute_time();
    _lastWfiTicks = 0;
    _lastWfiIdlePct = 0.0;
    _vmStatus = [NSString stringWithFormat:@"Running Windows 11 ARM64 (%d vCPUs, %llu MB RAM)", _configuredCPUs, _configuredRamMB];
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];

    hv_winvm_start(1, vm_exit_trampoline);

    [self startDiagTimer];
    dispatch_async(_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
    [self notifyChanged];
}

- (void)startDiagTimer {
    [self stopDiagTimer];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _diagQueue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                              8ull * NSEC_PER_SEC,
                              1ull * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf onDiagTickBackground];
    });
    _diagTimer = timer;
    dispatch_resume(timer);
}

- (void)stopDiagTimer {
    if (_diagTimer) {
        dispatch_source_cancel(_diagTimer);
        _diagTimer = nil;
    }
}

- (void)onDiagTickBackground {
    _diagTickCount++;
    [self writeDiagnosticsSnapshot];
    if (_vmRunning) {
        if ((_diagTickCount % 4u) == 0u) {
            hv_winvm_flush_disks();
        }
        if (getenv("WINIOS_ALWAYS_SCREENSHOT") != NULL) {
            NSString *docs = [self documentsPath];
            NSString *tmpPng = [docs stringByAppendingPathComponent:@"latest_screen.png.tmp"];
            NSString *dstPng = [docs stringByAppendingPathComponent:@"latest_screen.png"];
            if (hv_winvm_save_png(tmpPng.fileSystemRepresentation) == 0) {
                rename(tmpPng.fileSystemRepresentation, dstPng.fileSystemRepresentation);
            }
        }
    }
    [self notifyChanged];
}

- (void)writeDiagnosticsSnapshot {
    NSString *docs = [self documentsPath];
    NSString *statusFile = [docs stringByAppendingPathComponent:@"boot_status.txt"];
    BOOL running = _vmRunning;
    double uptime = running ? (CFAbsoluteTimeGetCurrent() - _bootStartTime) : 0.0;
    uint32_t w = [self framebufferWidth], h = [self framebufferHeight];
    uint64_t frames = [self presentedFrames];

    int kbdReady = 0, tabReady = 0;
    uint64_t usbDelivered = 0;
    uint64_t jitUsedBytes = 0, jitCapBytes = 0, jitFullFlushes = 0, wfiTicks = 0;
    double wfiIdlePct = _lastWfiIdlePct;
    if (running) {
        hv_winvm_usb_stats(&kbdReady, &tabReady, &usbDelivered);
        hv_winvm_engine_stats(&jitUsedBytes, &jitCapBytes, &jitFullFlushes, &wfiTicks);
        uint64_t nowMach = mach_absolute_time();
        if (_lastMachTicks > 0 && nowMach > _lastMachTicks && wfiTicks >= _lastWfiTicks && _configuredCPUs > 0) {
            double pct = 100.0 * (double)(wfiTicks - _lastWfiTicks) /
                         ((double)(nowMach - _lastMachTicks) * (double)_configuredCPUs);
            if (pct < 0.0) pct = 0.0;
            if (pct > 100.0) pct = 100.0;
            wfiIdlePct = pct;
            _lastWfiIdlePct = pct;
        }
        _lastMachTicks = nowMach;
        _lastWfiTicks = wfiTicks;
    }

    os_unfair_lock_lock(&_metricsLock);
    CGSize pt = _screenSizePts;
    CGFloat scale = _screenScale;
    NSInteger hingeStatus = _hingeStatus;
    double hingeDeg = _hingeAngleDegrees;
    os_unfair_lock_unlock(&_metricsLock);

    NSString *txt = [NSString stringWithFormat:
        @"vm_running: %@\n"
        @"vm_status: %@\n"
        @"jit_live: %@\n"
        @"jit_status: %@\n"
        @"uptime_sec: %.1f\n"
        @"cpus: %d\n"
        @"ram_mb: %llu\n"
        @"avail_mem_mb: %llu\n"
        @"jit_used_mb: %.1f\n"
        @"jit_cap_mb: %.0f\n"
        @"jit_full_flushes: %llu\n"
        @"wfi_idle_pct: %.1f\n"
        @"fb_size: %ux%u\n"
        @"frames_presented: %llu\n"
        @"usb_kbd_ready: %d\n"
        @"usb_tab_ready: %d\n"
        @"usb_delivered: %llu\n"
        @"share_up: %d\n"
        @"oauth_safari: %d\n"
        @"hinge_status: %ld\n"
        @"hinge_angle_deg: %.1f\n"
        @"screen_pts: %.0fx%.0f @%.0fx\n",
        running ? @"true" : @"false",
        _vmStatus ?: @"",
        self.isJITLive ? @"true" : @"false",
        self.jitStatusText ?: @"",
        uptime,
        _configuredCPUs,
        _configuredRamMB,
        [self availableMemoryMB],
        (double)jitUsedBytes / (1024.0 * 1024.0),
        (double)jitCapBytes / (1024.0 * 1024.0),
        jitFullFlushes,
        wfiIdlePct,
        w, h,
        frames,
        kbdReady,
        tabReady,
        usbDelivered,
        running ? hv_winvm_share_up() : 0,
        hv_share_url_handler_enabled(),
        (long)hingeStatus,
        hingeDeg,
        pt.width, pt.height, scale];
    [txt writeToFile:statusFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)handleVMExitWithReason:(NSString *)reason {
    _vmRunning = NO;
    [self stopDiagTimer];
    [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
    _vmStatus = [NSString stringWithFormat:@"Stopped (%@)", reason];
    dispatch_async(_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
    [self notifyChanged];
}

- (void)sendTabletNormalizedX:(double)x y:(double)y buttons:(uint8_t)buttons wheel:(int8_t)wheel {
    if (!_vmRunning) return;
    hv_winvm_tablet(x, y, buttons, wheel);
}

- (void)sendTabletNormalizedX:(double)x y:(double)y buttons:(uint8_t)buttons wheel:(int8_t)wheel horizontalWheel:(int8_t)horizontalWheel {
    if (!_vmRunning) return;
    hv_winvm_tablet_scroll(x, y, buttons, wheel, horizontalWheel);
}

- (void)sendKeyHid:(uint8_t)usage down:(BOOL)down {
    if (!_vmRunning) return;
    hv_winvm_key_hid(usage, down ? 1 : 0);
}

- (void)tapKeyHid:(uint8_t)usage {
    if (!_vmRunning) return;
    hv_winvm_key_hid(usage, 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        hv_winvm_key_hid(usage, 0);
    });
}

- (void)sendKeyComboWithModifiers:(NSArray<NSNumber *> *)modifiers key:(uint8_t)usage {
    if (!_vmRunning) return;
    for (NSNumber *m in modifiers) {
        hv_winvm_key_hid((uint8_t)m.unsignedCharValue, 1);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(18 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (usage != 0) hv_winvm_key_hid(usage, 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(38 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            if (usage != 0) hv_winvm_key_hid(usage, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                for (NSNumber *m in [modifiers reverseObjectEnumerator]) {
                    hv_winvm_key_hid((uint8_t)m.unsignedCharValue, 0);
                }
            });
        });
    });
}

- (void)sendWindowsKey {
    [self tapKeyHid:0xe3]; /* Left GUI / Windows key */
}

- (void)sendEscape {
    [self tapKeyHid:0x29]; /* Escape */
}

- (void)sendAltTab {
    [self sendKeyComboWithModifiers:@[@(0xe2)] key:0x2b];
}

- (void)sendCtrlAltDel {
    if (!_vmRunning) return;
    hv_winvm_send_ctrl_alt_del();
}

- (void)pressPowerButton {
    if (!_vmRunning) return;
    hv_winvm_power_button();
}

- (void)flushDisks {
    if (!_vmRunning) return;
    hv_winvm_flush_disks();
}

- (void)stopVM {
    if (!_vmRunning) return;
    hv_winvm_stop();
}

- (BOOL)useSafariForGuestLinks {
    return hv_share_url_handler_enabled() != 0;
}

- (void)setUseSafariForGuestLinks:(BOOL)useSafariForGuestLinks {
    hv_share_set_url_handler_enabled(useSafariForGuestLinks ? 1 : 0);
    [[NSUserDefaults standardUserDefaults] setBool:useSafariForGuestLinks forKey:@"winios.safariOAuthV2"];
}

- (nullable NSString *)takeGuestOpenURL {
    char *raw = hv_share_take_open_url();
    if (!raw) return nil;
    NSString *s = [NSString stringWithUTF8String:raw];
    free(raw);
    return s;
}

- (BOOL)takeGuestOAuthDone {
    return hv_share_take_oauth_done() != 0;
}

@end
