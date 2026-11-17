/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Dual-mapped RX/RW JIT allocator for iOS 17..27 (including iOS 26/27 TXM).
 * Adapted from Henge (Leviidev/Henge, GPL-2.0-or-later).
 */
#include "winios_jit.h"
#include "guest_memory.h"
#include "winvirt.h"

#include <TargetConditionals.h>
#include <errno.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/task.h>
#include <mach/task_info.h>
#include <mach/vm_map.h>
#include <os/log.h>
#include <os/proc.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/sysctl.h>
#include <sys/ucontext.h>
#include <unistd.h>

/* Provide pipe2 if referenced by static glib/slirp on older iOS runtimes. */
__attribute__((weak, visibility("default")))
int pipe2(int fds[2], int flags) {
    if (!fds) {
        errno = EFAULT;
        return -1;
    }
    if (pipe(fds) < 0) return -1;
    if ((flags & O_CLOEXEC) &&
        (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0)) {
        int e = errno;
        close(fds[0]);
        close(fds[1]);
        errno = e;
        return -1;
    }
    if (flags & O_NONBLOCK) {
        int f0 = fcntl(fds[0], F_GETFL), f1 = fcntl(fds[1], F_GETFL);
        if (f0 < 0 || f1 < 0 ||
            fcntl(fds[0], F_SETFL, f0 | O_NONBLOCK) < 0 ||
            fcntl(fds[1], F_SETFL, f1 | O_NONBLOCK) < 0) {
            int e = errno;
            close(fds[0]);
            close(fds[1]);
            errno = e;
            return -1;
        }
    }
    return 0;
}

extern void    *winios_brk_get_jit_mapping(void *addr, size_t len);
extern void     winios_brk_jit_detach(void);
extern uint64_t winios_brk_probe(void);
extern const uint8_t winios_brk_probe_trap[];
extern const uint8_t winios_brk_mapping_trap[];
extern const uint8_t winios_brk_detach_trap[];

/* Helpers write this process-local word only after attaching and before
 * resuming. CS_DEBUGGED alone also covers ordinary Xcode Run and can remain
 * set after detach, so it cannot authorize the custom BRK protocol. */
__attribute__((used, visibility("default"), aligned(8)))
_Atomic uint64_t winios_jit_helper_token;
#define WINIOS_JIT_HELPER_READY UINT64_C(0x574A4954)

uint64_t winios_jit_helper_token_address(void) {
    return (uint64_t)(uintptr_t)&winios_jit_helper_token;
}

#define WINIOS_LOG(fmt, ...)                                              \
    do {                                                                  \
        os_log(OS_LOG_DEFAULT, "[winios-jit] " fmt, ##__VA_ARGS__);       \
        fprintf(stderr, "[winios-jit] " fmt "\n", ##__VA_ARGS__);         \
        fflush(stderr);                                                   \
    } while (0)

/* Executable JIT pages above 0x7000000000 hang on iOS 26/27 TXM devices.
 * Reserve a 512 MiB zero-fill block in __DATA at launch so it sits inside the
 * low < 0x180000000 window, then deallocate it immediately before debugserver's
 * `_M<size>,rx` allocation takes the first-fit hole. */
#define WINIOS_JIT_LOW_LIMIT 0x7000000000ull
__attribute__((used, aligned(16384)))
static uint8_t g_jit_reserve[WINIOS_JIT_DEFAULT_BYTES + (16u << 10)];
static bool g_jit_reserve_released;

static _Thread_local uintptr_t g_expected_jit_trap_pc;
static struct sigaction g_prev_sigtrap;
static bool g_trap_handler_installed;

static WinIosDualMapping g_mapping;
static void *g_guest_ram;
static uint64_t g_guest_ram_bytes;
static WinIosGuestRamKind g_ram_kind = WINIOS_GUEST_RAM_NONE;
static bool g_ledger_allocation_failed;
static uint64_t g_requested_guest_mb = 4096;
static atomic_bool g_jit_live;
static char g_status[256] = "Not initialized";
static pthread_mutex_t g_ram_status_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_ram_allocation_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_ram_status[512] = "Guest RAM has not been reserved.";

static void set_ram_status(const char *message) {
    pthread_mutex_lock(&g_ram_status_lock);
    snprintf(g_ram_status, sizeof g_ram_status, "%s", message);
    pthread_mutex_unlock(&g_ram_status_lock);
}

/* Caller holds the status lock. */
static void describe_ram_mapping_locked(uint64_t memory_mb, WinIosGuestRamKind kind) {
    if (kind == WINIOS_GUEST_RAM_FILE_BACKED)
        snprintf(g_ram_status, sizeof g_ram_status,
                 "Reserved exactly %llu MiB in a disk-backed guest mapping with allocated storage. Pages are loaded on demand; this is not a physical RAM commitment.",
                 (unsigned long long)memory_mb);
    else
        snprintf(g_ram_status, sizeof g_ram_status,
                 "Reserved exactly %llu MiB in a ledger-exempt guest mapping. This does not commit all physical pages.",
                 (unsigned long long)memory_mb);
}

void winios_jit_copy_guest_ram_status(char *buffer, size_t size) {
    if (!buffer || !size) return;
    pthread_mutex_lock(&g_ram_status_lock);
    snprintf(buffer, size, "%s", g_ram_status);
    pthread_mutex_unlock(&g_ram_status_lock);
}

/* Serialized with startup reservation; diagnostic readers use the status lock. */
static void prealloc_ledger_exempt_ram_locked(void) {
    if (g_guest_ram) return;
    if (getenv("HV_RAM_NO_LEDGER")) {
        set_ram_status("Ledger-exempt allocation is disabled; a disk-backed guest mapping will be reserved at startup.");
        return;
    }
    uint64_t phys_mem = 0;
    size_t len = sizeof phys_mem;
    if (sysctlbyname("hw.memsize", &phys_mem, &len, NULL, 0) != 0) {
        int error = errno;
        set_ram_status("Physical RAM query failed; guest RAM was not reserved by the JIT helper.");
        WINIOS_LOG("guest RAM physical-memory query failed: errno %d (%s)", error, strerror(error));
        return;
    }
    /* Reserve the configured Windows 11 minimum or larger, without silently
     * shrinking the guest or assuming the memory ledger exception will work. */
    uint64_t mb = g_requested_guest_mb;
    if (mb >= HV_GUEST_MIN_MEMORY_MB && mb <= hv_guest_memory_limit_mb(phys_mem)) {
        uint8_t *p = hv_alloc_no_footprint(mb << 20);
        if (p) {
            pthread_mutex_lock(&g_ram_status_lock);
            g_guest_ram = p;
            g_guest_ram_bytes = mb << 20;
            g_ram_kind = WINIOS_GUEST_RAM_LEDGER_EXEMPT;
            pthread_mutex_unlock(&g_ram_status_lock);
            set_ram_status("JIT helper reserved a ledger-exempt guest mapping. Reservation does not commit all physical pages.");
            WINIOS_LOG("pre-allocated %llu MiB ledger-exempt Guest RAM at %p",
                       (unsigned long long)mb, (void *)p);
            return;
        }
        g_ledger_allocation_failed = true;
        set_ram_status("Ledger-exempt allocation was refused; startup will try an exact-size disk-backed guest mapping. See the kernel allocation error in the device log.");
    } else {
        set_ram_status("Requested RAM is outside the physical-memory admission range; guest RAM was not reserved.");
        WINIOS_LOG("guest RAM reservation skipped: requested=%llu MiB physical=%llu MiB maximum=%llu MiB",
                   (unsigned long long)mb, (unsigned long long)(phys_mem >> 20),
                   (unsigned long long)hv_guest_memory_limit_mb(phys_mem));
    }
    WINIOS_LOG("ledger-exempt Guest RAM pre-allocation unavailable; will fall back at VM start");
}

static void prealloc_ledger_exempt_ram(void) {
    pthread_mutex_lock(&g_ram_allocation_lock);
    prealloc_ledger_exempt_ram_locked();
    pthread_mutex_unlock(&g_ram_allocation_lock);
}

bool winios_jit_reserve_guest_ram(uint64_t memory_mb, const char *backing_template,
                                 char *error, size_t error_size) {
    if (error && error_size) error[0] = '\0';
    if (memory_mb < HV_GUEST_MIN_MEMORY_MB || memory_mb > HV_GUEST_MAP_MAX_MEMORY_MB ||
            memory_mb > (uint64_t)(SIZE_MAX >> 20)) {
        if (error && error_size)
            snprintf(error, error_size, "Guest RAM request %llu MiB is outside the supported mapping range.",
                     (unsigned long long)memory_mb);
        return false;
    }

    uint64_t bytes = memory_mb << 20;
    pthread_mutex_lock(&g_ram_allocation_lock);
    if (g_guest_ram && g_guest_ram_bytes == bytes) {
        pthread_mutex_lock(&g_ram_status_lock);
        describe_ram_mapping_locked(memory_mb, g_ram_kind);
        pthread_mutex_unlock(&g_ram_status_lock);
        pthread_mutex_unlock(&g_ram_allocation_lock);
        return true;
    }

    uint8_t *mapping = NULL;
    WinIosGuestRamKind kind = WINIOS_GUEST_RAM_NONE;
    if (!g_ledger_allocation_failed && !getenv("HV_RAM_NO_LEDGER")) {
        mapping = hv_alloc_no_footprint(bytes);
        if (mapping) kind = WINIOS_GUEST_RAM_LEDGER_EXEMPT;
        else g_ledger_allocation_failed = true;
    }
    char allocation_error[512] = {0};
    if (!mapping) {
        mapping = hv_alloc_file_backed_ram(bytes, backing_template, allocation_error, sizeof allocation_error);
        if (mapping) kind = WINIOS_GUEST_RAM_FILE_BACKED;
    }
    if (!mapping) {
        if (!allocation_error[0])
            snprintf(allocation_error, sizeof allocation_error, "Cannot reserve %llu MiB of disk-backed guest RAM.",
                     (unsigned long long)memory_mb);
        if (error && error_size) snprintf(error, error_size, "%s", allocation_error);
        char status[512];
        snprintf(status, sizeof status, "Reservation failed: %.320s Previous reservation retained: %llu MiB.",
                 allocation_error, (unsigned long long)(g_guest_ram_bytes >> 20));
        set_ram_status(status);
        WINIOS_LOG("guest RAM reservation failed: %s", allocation_error);
        pthread_mutex_unlock(&g_ram_allocation_lock);
        return false;
    }

    pthread_mutex_lock(&g_ram_status_lock);
    void *old_mapping = g_guest_ram;
    uint64_t old_bytes = g_guest_ram_bytes;
    WinIosGuestRamKind old_kind = g_ram_kind;
    g_guest_ram = mapping;
    g_guest_ram_bytes = bytes;
    g_ram_kind = kind;
    describe_ram_mapping_locked(memory_mb, kind);
    pthread_mutex_unlock(&g_ram_status_lock);

    if (old_mapping) {
        if (old_kind == WINIOS_GUEST_RAM_FILE_BACKED) {
            if (munmap(old_mapping, (size_t)old_bytes) != 0)
                WINIOS_LOG("previous disk-backed guest mapping release failed: errno %d (%s)", errno, strerror(errno));
        } else {
            kern_return_t kr = vm_deallocate(mach_task_self(), (vm_address_t)old_mapping, (vm_size_t)old_bytes);
            if (kr != KERN_SUCCESS)
                WINIOS_LOG("previous ledger guest mapping release failed: %s (kernel code %d)", mach_error_string(kr), kr);
        }
    }
    WINIOS_LOG("reserved %llu MiB guest RAM using %s mapping at %p",
               (unsigned long long)memory_mb,
               kind == WINIOS_GUEST_RAM_FILE_BACKED ? "disk-backed" : "ledger-exempt", (void *)mapping);
    pthread_mutex_unlock(&g_ram_allocation_lock);
    return true;
}

void winios_jit_set_guest_memory_mb(uint64_t memory_mb) {
    if (memory_mb >= HV_GUEST_MIN_MEMORY_MB && memory_mb <= HV_GUEST_MAP_MAX_MEMORY_MB)
        g_requested_guest_mb = memory_mb;
}

static void set_status(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void set_status(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_status, sizeof g_status, fmt, ap);
    va_end(ap);
}

static void winios_trap_handler(int sig, siginfo_t *info, void *ctx) {
    (void)info;
    if (sig == SIGTRAP && g_expected_jit_trap_pc && ctx != NULL) {
        ucontext_t *uc = (ucontext_t *)ctx;
        uintptr_t pc = (uintptr_t)uc->uc_mcontext->__ss.__pc;
        if (pc == g_expected_jit_trap_pc) {
            uint32_t opcode = *(const uint32_t *)pc;
            uint32_t expected = 0xd4200000u | ((pc == (uintptr_t)winios_brk_probe_trap ? 0x69u : 0xf00du) << 5);
            if (opcode == expected) {
                uc->uc_mcontext->__ss.__pc += 4;
                uc->uc_mcontext->__ss.__x[0] = 0;
                return;
            }
        }
    }
    sigaction(sig, &g_prev_sigtrap, NULL);
    raise(sig);
}

void winios_jit_install_trap_handler(void) {
    if (g_trap_handler_installed) return;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sa.sa_sigaction = winios_trap_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTRAP, &sa, &g_prev_sigtrap);
    g_trap_handler_installed = true;
    set_status("Trap guard ready");
    WINIOS_LOG("trap guard installed");
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
bool winios_jit_is_debugger_attached(void) {
    uint32_t flags = 0;
    return syscall(169 /* SYS_csops */, getpid(), 0 /* CS_OPS_STATUS */, &flags, sizeof flags) == 0 &&
           (flags & 0x10000000u) != 0; /* CS_DEBUGGED */
}
#pragma clang diagnostic pop

size_t winios_available_memory_bytes(void) {
#if TARGET_OS_IPHONE
    return os_proc_available_memory();
#else
    return 4ull << 30;
#endif
}

bool winios_process_footprint_bytes(uint64_t *out_bytes) {
    if (!out_bytes) return false;
    *out_bytes = 0;
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS || count < TASK_VM_INFO_REV1_COUNT) return false;
    *out_bytes = info.phys_footprint;
    return true;
}

static void release_low_hold(size_t bytes) {
    if (g_jit_reserve_released || bytes > WINIOS_JIT_DEFAULT_BYTES) return;
    vm_address_t start = ((vm_address_t)g_jit_reserve + 16383) & ~(vm_address_t)16383;
    kern_return_t kr = vm_deallocate(mach_task_self(), start, WINIOS_JIT_DEFAULT_BYTES);
    WINIOS_LOG("released low __DATA hold at %#lx (%zu MiB): %s",
               (unsigned long)start, WINIOS_JIT_DEFAULT_BYTES >> 20, mach_error_string(kr));
    g_jit_reserve_released = true;
}

static bool jit_selftest(const WinIosDualMapping *m) {
    /* movz w0, #42 ; ret */
    static const uint32_t kCode[2] = {0x52800540u, 0xD65F03C0u};
    if (!m->rw_addr || !m->rx_addr || m->size < 16384) return false;

    const size_t offsets[2] = {0, m->size - 16384};
    for (int i = 0; i < 2; i++) {
        size_t off = offsets[i];
        memcpy(m->rw_addr + off, kCode, sizeof kCode);
        sys_icache_invalidate(m->rx_addr + off, sizeof kCode);

        uint32_t rb[2] = {0, 0};
        memcpy(rb, m->rx_addr + off, sizeof rb);
        if (rb[0] != kCode[0] || rb[1] != kCode[1]) {
            WINIOS_LOG("selftest FAIL at +%#zx: alias mismatch (%08x %08x)", off, rb[0], rb[1]);
            return false;
        }
        int (*fn)(void) = (int (*)(void))(void *)(m->rx_addr + off);
        int rc = fn();
        if (rc != 42) {
            WINIOS_LOG("selftest FAIL at +%#zx: expected 42, got %d", off, rc);
            return false;
        }
    }
    WINIOS_LOG("selftest PASS: executed RX code at %p and +%#zx -> 42",
               (void *)m->rx_addr, m->size - 16384);
    return true;
}

bool winios_jit_acquire(size_t bytes, bool detach_after) {
    if (atomic_load(&g_jit_live)) return true;
    if (bytes == 0) bytes = WINIOS_JIT_DEFAULT_BYTES;
    bytes = (bytes + 0x3fffu) & ~(size_t)0x3fffu;

    if (!winios_jit_is_debugger_attached()) {
        atomic_store(&winios_jit_helper_token, 0);
        set_status("Waiting for debugger (StikDebug or LLDB)");
        WINIOS_LOG("acquire: CS_DEBUGGED not set yet");
        return false;
    }

    if (atomic_load_explicit(&winios_jit_helper_token, memory_order_acquire) != WINIOS_JIT_HELPER_READY) {
        set_status("JIT helper required: Xcode Run alone cannot service JIT. Use launch_on_device.sh or Enable JIT.");
        WINIOS_LOG("acquire: debugger present without the JIT helper handshake; no BRK emitted");
        return false;
    }

    g_expected_jit_trap_pc = (uintptr_t)winios_brk_probe_trap;
    uint64_t probe = winios_brk_probe();
    g_expected_jit_trap_pc = 0;

    if (probe == 0) {
        /* Pre-iOS 26 fallback where CS_DEBUGGED permits plain vm_remap RX/RW without trap servicing */
        if (!__builtin_available(iOS 26.0, *)) {
            release_low_hold(bytes);
            uint8_t *rx = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
            if (rx != MAP_FAILED) {
                vm_address_t rw = 0;
                vm_prot_t cur, max;
                if (vm_remap(mach_task_self(), &rw, bytes, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                             (vm_address_t)rx, FALSE, &cur, &max, VM_INHERIT_NONE) == KERN_SUCCESS &&
                    vm_protect(mach_task_self(), (vm_address_t)rx, bytes, FALSE,
                               VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS &&
                    vm_protect(mach_task_self(), rw, bytes, FALSE,
                               VM_PROT_READ | VM_PROT_WRITE) == KERN_SUCCESS) {
                    WinIosDualMapping m = {(uint8_t *)rw, rx, bytes};
                    if (jit_selftest(&m)) {
                        g_mapping = m;
                        set_ram_status("Plain RX/RW JIT is active; guest RAM will use the normal allocator at VM startup.");
                        atomic_store(&g_jit_live, true);
                        set_status("Live (%zu MiB plain RX/RW)", bytes >> 20);
                        return true;
                    }
                }
                munmap(rx, bytes);
            }
        }
        set_status("Debugger attached, waiting for brk trap handler");
        WINIOS_LOG("probe returned 0 (debugger did not answer brk #0x69)");
        return false;
    }

    if (probe != UINT64_C(0xE0000069)) {
        atomic_store(&winios_jit_helper_token, 0);
        set_status("JIT helper returned an invalid protocol response; relaunch using the supplied helper.");
        return false;
    }

    WINIOS_LOG("probe answered: 0x%llx", (unsigned long long)probe);
    release_low_hold(bytes);

    void *rx = NULL;
    for (int attempt = 1; attempt <= 3; attempt++) {
        g_expected_jit_trap_pc = (uintptr_t)winios_brk_mapping_trap;
        rx = winios_brk_get_jit_mapping(NULL, bytes);
        g_expected_jit_trap_pc = 0;
        if (rx != NULL) break;
        usleep(50 * 1000);
    }

    if (!rx) {
        set_status("Failed: debugger returned NULL RX region");
        return false;
    }
    if ((uint64_t)(uintptr_t)rx + bytes > WINIOS_JIT_LOW_LIMIT) {
        WINIOS_LOG("RX region %p above %#llx limit; releasing", rx, WINIOS_JIT_LOW_LIMIT);
        vm_deallocate(mach_task_self(), (vm_address_t)rx, bytes);
        set_status("Failed: RX allocated above low limit (relaunch app)");
        return false;
    }

    /* Map writable alias within +-2 GiB of RX if possible, otherwise anywhere */
    vm_address_t rw = 0;
    vm_prot_t cur_prot = VM_PROT_NONE, max_prot = VM_PROT_NONE;
    kern_return_t kr = KERN_NO_SPACE;
    const uintptr_t step = 16u << 20, reach = (uintptr_t)2 << 30;
    for (uintptr_t off = 0; off <= reach && kr != KERN_SUCCESS; off += step) {
        for (int side = 0; side < 2 && kr != KERN_SUCCESS; side++) {
            uintptr_t want = side == 0 ? (uintptr_t)rx + bytes + off : (uintptr_t)rx - bytes - off;
            if (side == 1 && (uintptr_t)rx < bytes + off + step) continue;
            rw = (vm_address_t)want;
            kr = vm_remap(mach_task_self(), &rw, (vm_size_t)bytes, 0, VM_FLAGS_FIXED,
                          mach_task_self(), (vm_address_t)rx, FALSE, &cur_prot, &max_prot, VM_INHERIT_NONE);
        }
    }
    if (kr != KERN_SUCCESS) {
        rw = 0;
        kr = vm_remap(mach_task_self(), &rw, (vm_size_t)bytes, 0, VM_FLAGS_ANYWHERE,
                      mach_task_self(), (vm_address_t)rx, FALSE, &cur_prot, &max_prot, VM_INHERIT_NONE);
    }
    if (kr != KERN_SUCCESS) {
        set_status("Failed: vm_remap (%s)", mach_error_string(kr));
        vm_deallocate(mach_task_self(), (vm_address_t)rx, bytes);
        return false;
    }

    kr = vm_protect(mach_task_self(), rw, (vm_size_t)bytes, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        set_status("Failed: vm_protect RW (%s)", mach_error_string(kr));
        vm_deallocate(mach_task_self(), rw, bytes);
        vm_deallocate(mach_task_self(), (vm_address_t)rx, bytes);
        return false;
    }

    WinIosDualMapping m = {(uint8_t *)rw, (uint8_t *)rx, bytes};
    if (!jit_selftest(&m)) {
        set_status("Failed: TXM selftest rejected RX execution");
        vm_deallocate(mach_task_self(), rw, bytes);
        vm_deallocate(mach_task_self(), (vm_address_t)rx, bytes);
        return false;
    }

    g_mapping = m;
    prealloc_ledger_exempt_ram();
    atomic_store(&g_jit_live, true);
    atomic_store(&winios_jit_helper_token, 0);

    if (detach_after) {
        WINIOS_LOG("detaching debugger; %zu MiB RX=%p RW=%p, GuestRAM=%llu MiB stays live",
                   bytes >> 20, (void *)m.rx_addr, (void *)m.rw_addr,
                   (unsigned long long)(g_guest_ram_bytes >> 20));
        g_expected_jit_trap_pc = (uintptr_t)winios_brk_detach_trap;
        winios_brk_jit_detach();
        g_expected_jit_trap_pc = 0;
    }

    set_status("Live (%zu MiB TXM JIT, %llu MiB RAM)", bytes >> 20,
               (unsigned long long)(g_guest_ram_bytes >> 20));
    return true;
}

bool winios_jit_is_live(void) {
    return atomic_load(&g_jit_live);
}

WinIosDualMapping winios_jit_mapping(void) {
    return g_mapping;
}

void *winios_jit_guest_ram(uint64_t *out_bytes) {
    pthread_mutex_lock(&g_ram_status_lock);
    if (out_bytes) *out_bytes = g_guest_ram_bytes;
    void *ram = g_guest_ram;
    pthread_mutex_unlock(&g_ram_status_lock);
    return ram;
}

WinIosGuestRamKind winios_jit_guest_ram_kind(void) {
    pthread_mutex_lock(&g_ram_status_lock);
    WinIosGuestRamKind kind = g_ram_kind;
    pthread_mutex_unlock(&g_ram_status_lock);
    return kind;
}

const char *winios_jit_status_text(void) {
    return g_status;
}
