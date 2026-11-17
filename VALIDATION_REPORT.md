# WindowsiOS verification report

Latest unified-app evidence (2026-11-15): **UTM ARM Lab** builds and signs with
the actual UTM frontend and both native engine frameworks. IPA SHA-256:
`60779822a7c989bc1182576ffd26d4b071d4f49b7093b251e3cdb0f83bc0d026`.
Strict signatures, memory-profile grants, isolated native exports and exact
embedded-module JIT symbols pass. Native machine import/save/error-path tests,
input normalization checks and the real Metal aligned-texture harness pass.
The latter covers the small BGRA8/RGBA16F layouts rejected in the device log,
real rendering/aliasing, successive writes and full-size half-float output.
These checks establish the implementation and build; the unified app has not
yet run a guest on the iPad. The user's active Henge/Geekbench session was
preserved. See [full evidence and remaining device work](docs/UNIFIED_UTM.md).

Date: **2026-11-15**, America/Toronto. Target: **Windows 11 24H2 ARM64**,
confirmed by the user. Canonical branch: `main`; the implementation was
developed on `codex/ipad-24h2-build`; integration is recorded in
[PR #1](https://github.com/Thomas20090425/Windows-on-iOS/pull/1).
Initial universal-app implementation commit: `69b2e7e`. This report now covers
the ISO-only setup correction `01b9340`, startup/deletion correction `99dbef2`,
and the software TPM/input plus networking, CPU identity and VirtIO display updates.

## Verification scope

For the earlier Windows work, the user explicitly limited work to making the application build and prohibited
tests/debugging/VM execution on this Mac. After that instruction, verification
was limited to compilation, source inspection and artifact packaging/signature
inspection. No simulator, app, guest, debugger or performance workload was run.
Baseline core regression checks had already completed before that instruction;
they do not validate the subsequently added app/device changes.

The later UTM/macOS research request explicitly authorized device installation,
JIT, Apple IPSW download and guest restore/execution. Source-built full UTM and
Henge are installed on the M5 iPad; Henge's 512 MiB JIT RX self-test returned 42,
the Apple Sequoia 15.6.1 restore returned 0 / step 100, and the new 6 GiB guest booted
to animated Setup Assistant through the Metal/PVG renderer. The user chose to
complete account setup, so no account was created and the command queue was
cleared. These are actual research runtime results, separate from the older
Windows build-only evidence below. See [complete research record](docs/VIRTUALIZATION_RESEARCH.md).

WindowsiOS's nine settings pages, notes/search and Engines hub built in signed
Release (`build/logs/utm-style-windows-app-build.log`). Its installed original
Windows guest reports running; the update was staged to preserve that session.
UTM's app installation is verified, but its guest execution is untested here.

### RAM reservation rejection correction

The user reported failure even at 4 GiB in the original Windows 11 app. A
read-only installed-app listing confirmed `me.ammaar.windowsios`; the existing
device `Documents/boot_status.txt` was copied to
`build/ipad-memory-failure-status.txt`. It shows JIT live, 0 MiB reserved guest
RAM and 4698 MiB remaining process allowance. The old check required 5120 MiB
for a 4096 MiB guest and ran before the available file-backed allocator.

The corrected flow reserves exact guest bytes before process-global engine
creation, checks engine headroom separately and uses a fully allocated unique
temporary backing file when the special ledger mapping is unavailable. File
storage is reserved with F_PREALLOCATE/F_ALLOCATEALL, mapped lazily and
unlinked; actual allocation failures stop cleanly without an anonymous
fallback. Changed sizes replace old reservations only after success, permitting
retries before engine creation. Both signed app identities receive this fix.

Read-only device metadata/status inspection did not launch the app, a VM or a
debugger. No allocation or guest execution was performed by the agent.

Both corrected Release variants compiled with two workers, Xcode 27.2 / SDK
27.2. Signature/profile checks, IPA archive integrity and matching local JIT
symbol extraction passed:

| Variant | Build log | IPA SHA-256 |
| --- | --- | --- |
| Original ID, optional capabilities omitted | `build/logs/reservation-fixed-original-build.log` | `3ac81d86c5b36fb4d5de1e346b2e0b6e124ebc8fa14b367e1f2d8d55e10ae01d` |
| Windows 11 RAM, both capabilities granted | `build/logs/reservation-fixed-memory-build.log` | `51e042ec749352931a4e93259a963b24001d6f5081bb27bd64d1fa086686abbf` |

The first output is under `distribution/reservation-fixed-original/`, with
bundle ID `me.ammaar.windowsios`; the second replaces the earlier build under
`distribution/memory-enabled/`. No package was installed by the agent and no
4/6/8 GiB guest allocation was executed. Actual VA mapping, storage reservation
and guest working-set behavior remain unverified on the iPad.

### Earlier memory-capability build

The user identified their iPad as **iPad Pro (M5), 2 TB, 16 GB RAM**. The existing
physical admission formula already permits approximately 13 GiB on a 16 GiB
host; it does not explain a roughly 5 GiB allocation failure. Process memory
allowance, reservation failure and reservation-size mismatch now have separate
diagnostics and startup errors. iOS no longer eagerly touches every page of
the file-backed fallback at startup, and RAM metadata allocation failure now
stops startup.

The source recipe requests Increased Memory Limit and Extended Virtual
Addressing. Apple refused the original `me.ammaar.windowsios` registration for
this Mac's team, so the signed variant uses **com.thomas20090425.windowsios**
and display name **Windows 11 RAM**. Its explicit embedded provisioning profile
and app signature both contain both entitlements with value true. These grants
request device-dependent allowances; they do not prove 8 GiB guest execution.

Signed Release compilation succeeded with Xcode 27.2 / SDK 27.2 and two
workers: `build/logs/memory-enabled-build.log`. App signature and IPA integrity
passed; local JIT symbols were generated into `build/jit-symbols-memory-release.json`.
The previous distribution IPA hash was checked unchanged. New outputs are
under `distribution/memory-enabled/`; its IPA SHA-256 is:

```text
38570d3f349455972b13200a1b962d3d4a9da07e69a2d97b96269dd2fdee452d
```

No iPad installation, migration, guest allocation, app/VM/debugger/simulator
execution or tests were run. A separate app identifier requires the owner to
copy the complete existing VM folder into its new container before reuse.

### Display and keyboard correction

The user reported a fixed 800×600 desktop alongside the adjustable native
VirtIO screen. The bundled driver installer now installs a CCD display helper
that selects the identified connected VirtIO adapter as the sole active
desktop, preserves its current mode when available and saves the topology.
It also registers interactive sign-in selection; it does not change displays
in Windows Setup's session 0 or remove the firmware adapter. Existing Windows
installations need the updated `InstallDrivers.cmd` once, or can apply only the
current desktop repair with `UseVirtioDisplay.cmd` on WINIOSDRVS.

F1–F12 now starts hidden behind a floating F keys button and opens with a hide
arrow over the full guest viewport. The row no longer reserves a bottom inset.
The typing keyboard remains separate, and the viewport ignores keyboard safe
area changes.

Signed Release compilation succeeded with **Xcode 27.2 (27B52), iOS SDK 27.2**,
two workers. Log: `build/logs/display-keyboard-overlay-build.log`. Signature
verification and IPA archive integrity passed. Bundled helper source hashes
match provenance; generated and bundled driver disks match its image hash.
Local JIT symbol metadata was regenerated from the resulting app.

Earlier display/keyboard IPA SHA-256 (preserved at the original path):

```text
1b641afd3f5d983b3e481b083368b351ac7f3d30a3b19a20543c76d325ed97dd
```

This supersedes earlier artifact details below. The PowerShell/C# helper was
reviewed against the Windows CCD API, but was not executed or compiled in a
Windows guest. No device, simulator, debugger, VM or test workload ran for
this correction. Guest display switching and overlay interaction remain
device-unverified.

### Public source and build entry point

The source download includes the Swift, Objective-C, C and assembly app/engine
sources, `ios/project.yml`, build/preparation scripts, dependency patch and
license/provenance files. The Xcode project, dependency archives, firmware and
driver media are generated by the tracked recipes; `.gitignore` excludes those
outputs rather than the application source.

The root `Build.command` adds a Finder-launchable entry point for a downloaded
ZIP: it checks Xcode/Homebrew prerequisites, installs missing build tools and
calls the existing build script with two workers by default. Optional staging
from an ignored Husk reference checkout was removed from the dependency script;
the previously successful dependency build did not use that staging.

This packaging/entry-point update receives shell syntax, source, whitespace and
documentation-link checks only. No fresh dependency download/build, Homebrew
installation or Finder execution was performed. The signed app/IPA evidence
below still describes implementation revision `661b8ae`; the new entry point
does not establish a newly verified clean-machine build or runtime result.

## Evidence

| Deliverable/check | Result | Evidence and limit |
| --- | --- | --- |
| Native ARM64 iOS engine archive | **COMPILED** | `build/ios/libwinvm.a`, included in final signed app build. |
| Universal Swift/Objective-C/native application | **COMPILED** | `build/logs/ios-app-build-network-display-signed.log` ends with `BUILD SUCCEEDED`; includes networking/driver media, CPU identity, VirtIO GPU and resolution controls, plus prior TPM/input/ISO work. |
| Xcode Debug configuration | **EARLIER BUILD COMPILED** | `build/logs/ios-app-build-jit-delete-debug.log` covers the earlier startup/deletion changes. The current networking/display/TPM/input artifact was built in Release; no Debug runtime or device execution. |
| iPad device-target compilation | **COMPILED** | Generic `iphoneos` arm64 build; bundled `UIDeviceFamily` includes 2. No device run. |
| Duo/iPhone device-target compilation | **COMPILED** | Same universal arm64 artifact includes family 1; manual posture layout retained. Future hinge API excluded by SDK guard. No Duo run. |
| iOS dependencies | **COMPILED** | libffi 3.5.0, GLib 2.83.0, libslirp 4.9.1 and linked dependency archives staged in `ios/deps/`. |
| Signed app/IPA | **BUILT, SIGNATURE CHECKED** | `distribution/WindowsiOS.app`, `distribution/WindowsiOS-development.ipa`; `codesign --verify --strict` succeeded; IPA has `Payload/WindowsiOS.app`. |
| Build metadata | **RECORDED** | `distribution/BUILD_INFO.json`: arm64, iOS minimum 17.0, SDK 26.5, Xcode 26.6 (17F113), families [1,2]. |
| Bundled UEFI/variable template | **PACKAGED, HASHES CHECKED** | Matched 64 MiB `Firmware/code.fd` and `vars-template.fd` included in signed app. Pinned Debian EDK2 2025.02-8+deb13u1 package; manifest records hashes. Full licenses/provenance included. This proves packaged bytes, not firmware execution. |
| Software TPM 2.0 | **COMPILED; NOT RUNTIME-TESTED** | Static iOS arm64 libtpms 0.10.2 + OpenSSL 3.5.9. Actual command backend, CRB/FIFO MMIO, ACPI/FDT discovery, per-VM atomic NV storage, identity binding and reset/error handling compile. Library source/API and bundled firmware configuration reviewed. No TPM command, key-persistence, measured-boot, Windows enrollment or BitLocker workload executed. |
| Mouse buttons, numeric RAM and F1–F12 | **COMPILED; NOT DEVICE-TESTED** | Direct hardware button callbacks and passive UIKit pointer observation, held-state preservation, custom whole-MiB RAM with shared native bounds, hardware keyboard detection and actual guest F-key HID usages compile. No physical mouse/keyboard or RAM-allocation behavior verified. |
| Windows ARM64 network/display drivers | **PACKAGED; METADATA CHECKED** | Official pinned virtio-win 0.1.302-1. Selected SYS/EXE PE machine is 0xAA64, INF matches ARM64 and actual virtual devices, catalog publisher metadata is present, and the bundled 64 MiB FAT driver image hash matches provenance. No Windows trust/installation or Internet traffic run. |
| Virtual CPU model | **COMPILED; SOURCE REVIEWED** | Shared Cortex-A76 r4p1 MIDR/model/manufacturer/FDT constants; SMBIOS and app report the virtual compatibility profile. Feature execution was not exercised. |
| VirtIO GPU 2D and resolution control | **COMPILED; NOT RUNTIME-TESTED** | Real 2D resources/transfers/scanout/cursor/EDID, MSI-X mode-change events, framebuffer lifetime locks, native/window/preset controls and official guest resolution service. Firmware console remains RAMFB. No accelerated 3D or host GPU passthrough. Guest modesets unverified. |
| Baseline core regressions | **PASSED BEFORE SCOPE CHANGE** | `build/logs/core-baseline.log`: classifier 43 cases, operands 36 cases, JIT 10 programs × 2 seeds, memory 12 programs × 3 modes + MMIO, MMU 76 checks, exceptions 53 checks; all reported zero failures. JIT-region baseline also completed. No rerun after source changes. |
| New input/UI/config/lifecycle/storage tests | **NOT RUN — USER REQUEST** | Source and build checks only; no runtime assertions claimed. |
| JIT helper correction and VM deletion | **COMPILED; NOT RUNTIME-TESTED** | Release/Debug compile; exported readiness word and exact assembly trap labels are present in the packaged Mach-O. Python/JavaScript helper syntax checks passed. No helper attachment or user VM deletion executed. |
| Local symbols for device launcher | **METADATA PREPARED; NOT DEVICE-TESTED** | `build/jit-symbols-release.json` and `build/jit-symbols-debug.json` record Mach-O UUIDs/addresses from the local products, including the Debug dylib. Python/shell syntax compilation passed. No LLDB process was launched during this correction. |
| Serial JIT preparation baseline | **USER-TIMED; TOO SLOW ON THIS CONNECTION** | Bulk: 21 MiB/72.9 s projects 22.2 minutes. Serial sparse: 316/24,576 pages in 24.4 s projects about 31.6 minutes. Smaller payload did not overcome per-command cost. Neither log reaches completed JIT preparation. |
| Mac JIT batch transport | **USER CONNECTED; ATTACH ORDER CORRECTED; NOT DEVICE-TIMED** | User log reaches successful no-ack negotiation, then stalls in synchronous `process connect` before attachment. Corrected to asynchronous connection, bounded connected-state wait, synchronous exact-PID attachment and a 60 s startup watchdog. Python/shell syntax compilation and source review only for the correction. No tunnel, debugger, device or VM run by the agent. |
| Simulator UI checks | **NOT RUN — USER REQUEST** | Simulator compilation/execution is not native JIT verification. |
| Physical installation | **USER-REPORTED LAUNCH; NOT AGENT-TESTED** | User supplied devicectl output showing bundle `me.ammaar.windowsios` launched on device with PID 2377. Its precise build UUID was not logged. No installation or device launch executed by the agent. |
| Device JIT initialization | **PARTIAL USER-REPORTED EVIDENCE** | Latest supplied log shows helper readiness write/read-back, successful probe reply and allocation of 384 MiB RX memory at `0x1045e8000`. It does not show completed page preparation, RX execution self-check or helper detach. No debugger attachment performed by the agent. |
| UEFI/ISO boot and unattended Windows installation | **NOT TESTED** | Open-source firmware is now bundled, but no Windows ISO was supplied and VM execution was prohibited. No successful installation is claimed. |
| Keyboard/mouse/trackpad/Pencil | **NOT TESTED** | Native event → bridge → existing xHCI HID source path compiles; no physical or guest validation. |
| Guest network/audio/storage | **NOT TESTED** | Native backends and configuration compile; actual guest drivers, persistence and device behavior unverified. |
| Performance/thermal/Jetsam behavior | **NOT MEASURED — USER REQUEST** | No performance improvement, safe model matrix or boot-time result is claimed. |

Final signing used an existing local Apple Development identity and an eligible
Xcode-managed wildcard profile through automatic signing. The profile permits
**7 registered devices** and expires **2027-11-15 13:23:53 UTC**. Its
`get-task-allow` entitlement supports debugger attachment in principle, not proof
of JIT execution. An unregistered iPad requires a new eligible profile/rebuild.
No credentials or provisioning files were added to Git.

IPA SHA-256:

```text
5251bfa1a41465efcb1e7898412bdabd8effc79bc1097aaceb2c918bd9214d70
```

## Build issues resolved

- Missing Homebrew libslirp and build tooling prevented the initial baseline
  aggregate build; prerequisites and cross-compiled iOS dependencies supplied.
- Installed SDK 26.5 does not declare `UIHingeInteraction`; guarded original
  implementation behind `WINIOS_HINGE_SDK`, retaining manual posture controls.
- The zoom host's `gestureRecognizerShouldBegin` override was corrected after
  the compiler identified a missing `override` modifier.
- Xcode rejects an Xcode-managed provisioning profile in manual mode; normal
  automatic signing selected the eligible existing profile successfully.

## Delivered behavior and limits

The user reported `Thread 1: EXC_BREAKPOINT` while starting a VM and identified
`winios_brk.S` as the stopped source. Source inspection found that the prior
allocator treated `CS_DEBUGGED` as sufficient to emit its custom JIT protocol
traps. A normal Xcode Run debugger does not implement that protocol. The new
allocator requires a process-local readiness handshake from the matching LLDB
or StikDebug helper before emitting a probe, verifies the exact probe response,
and narrows signal fallback to the expected trap instruction. No general
breakpoint/Swift/host exception is skipped to make startup appear successful.
The supplied numeric PC alone did not establish an ASLR-resolved symbol; the
user's assembly source narrowed the diagnosis. Runtime reproduction was not
performed. Apple's [trap exception documentation](https://developer.apple.com/documentation/xcode/sigtrap_sigill)
also distinguishes debugger trap stops from other underlying runtime failures.

The user then supplied a Mac helper log where device launch/attachment succeeded
but LLDB could not resolve `winios_jit_helper_token`. The previous error wrongly
treated that as sufficient evidence of an outdated installed app. Local static
inspection establishes that the Release executable contains the symbol while
the Debug executable is an Xcode executor stub: Debug JIT symbols are in
`WindowsiOS.debug.dylib`. Which metadata was loaded in the user's remote target
was not captured, so the exact live resolution failure remains unverified.

Updated launchers accept a matching local `.app`, generate pure Mach-O metadata
before launching, and pass it to the helper. The helper uses strict image UUID
matching and each image's own `__TEXT` base for ASLR relocation, validates trap
instruction bytes before any readiness write, handles delayed Debug image
loading at a bounded bootstrap breakpoint, and reports mismatched builds
separately. Direct LLDB symbol lookup also accepts non-data classifications.
These use documented [LLDB module](https://lldb.llvm.org/python_api/lldb.SBModule.html)
and [target](https://lldb.llvm.org/python_api/lldb.SBTarget.html) APIs. Syntax
compilation and read-only local metadata preparation are the only new evidence;
no completed device JIT initialization or Windows boot is claimed.

A later user log now establishes partial device handshake progress: readiness
was armed/read back, `BRK #0x69` was answered and `_M` allocated 384 MiB RX.
It then repeatedly displayed “Locating external symbol file: WindowsiOS” with
no completed preparation message. That establishes the last reported stage,
not the duration or precise cause of a hang. LLDB uses the same status label
for local and external symbol searches, so it is not proof of network traffic.

The helper now disables external/background symbol search before attachment,
optionally disables automatic symbol downloads on LLDB versions supporting it,
loads a local dSYM only after UUID validation, and prints MiB/percentage/elapsed
progress in bulk and per-page memory preparation. Settings affect only that
LLDB session. A single blocked debugger call can still delay output; no bounded
device completion time is promised. Source reference: [LLDB symbol lookup settings](https://raw.githubusercontent.com/llvm/llvm-project/main/lldb/source/Core/CoreProperties.td).
Python/shell syntax compilation and read-only dSYM metadata preparation passed;
this specific change was not executed against a device.

The next user log established ongoing transfer rather than a proven hang:
21 MiB completed in 72.9 seconds. That measured bulk rate is unacceptable for
startup. Upstream [StikDebug page preparation](https://github.com/StikDebug/StikDebug/blob/f9c1f46fad389e6f46466777808eca99e9426c81/StikDebug/JSSupport/JSDebugSupport.swift#L89-L150)
writes one byte into each 16 KiB page. The helper now defaults to the same page
coverage through raw `M<address>,1:69` debugger commands, requiring an exact `OK`
for every page. The 384 MiB region remains unchanged and all 24,576 pages are
visited. Application RX alias/execution checks are unchanged. The payload
falls from 402,653,184 bytes to 24,576 bytes; this ratio is a deterministic byte
count, not a measured speedup. LLDB's serial command interface still incurs
24,576 round trips and does not reproduce StikDebug's 128-packet pipelining.

An explicit `WINIOS_JIT_PREPARE=bulk` diagnostic mode retains full-region writes
with `process plugin packet xfer-size 131072`, a documented command in
[LLVM's gdb-remote implementation](https://raw.githubusercontent.com/llvm/llvm-project/main/lldb/source/Plugins/Process/gdb-remote/ProcessGDBRemote.cpp).
The log does not identify the previously negotiated packet size, so it cannot
prove that a particular packet budget, network type or Mac CPU caused the
baseline. Python syntax compilation and source/protocol review passed; no
debugger or device/VM run was executed by the agent to measure the new path.

The user subsequently timed the serial sparse path: 316 pages after 24.4 s,
with the helper reporting an observed ETA of 31.2 minutes remaining. It was
slower than the bulk baseline on this connection. Reduced payload alone is not
a successful performance optimization here. StikDebug's native preparation
sends 128 page commands before reading their responses, addressing the serial
request/response cost; this source-based inference is not a measured WindowsiOS
speed guarantee. The existing app's custom-script URL handoff was checked
against current official StikDebug source: both schemes are registered,
URL-safe Base64 is decoded, PID-targeted custom scripts are accepted, and the
app supplies the handshake script automatically. No new app source or runtime
validation was performed for that review.

The user subsequently chose Mac-only launching. The default device launcher now
creates a no-root USB userspace debugproxy forwarder through pinned
`pymobiledevice3==11.55.1`, with an owned loopback RSP proxy between LLDB and that
forwarder. The proxy sends up to 128 page writes before collecting exactly that
many `OK` replies. The helper requests 8 MiB chunks, covering all 24,576 pages
in the unchanged 384 MiB allocation. Only successfully negotiated no-ack mode
and an observed target stop permit batching. The proxy refuses compression,
preserves ordinary wire packets, follows debugserver's dummy-checksum policy
after no-ack negotiation, and closes both connections on incomplete/unexpected
replies, interrupts or timeouts. Local UUID/instruction/readiness checks and
the native RX execution check are retained. A separate explicit Xcode fallback
compares bounded tuned-bulk/page samples and chooses the observed faster serial
method; it is not represented as a proven speed fix.

Source review used the pinned
[pymobiledevice3 debugserver implementation](https://github.com/doronz88/pymobiledevice3/blob/v11.55.1/pymobiledevice3/cli/developer/debugserver.py),
[StikDebug's native 128-command batching](https://github.com/StikDebug/StikDebug/blob/f9c1f46fad389e6f46466777808eca99e9426c81/StikDebug/JSSupport/JSDebugSupport.swift#L89-L150),
and [LLVM debugserver's RSP implementation](https://github.com/llvm/llvm-project/blob/main/lldb/tools/debugserver/source/RNBRemote.cpp).
Mac dependencies installed successfully and helper Python/shell syntax compiled.
No app source changed, so the existing signed app/IPA remains the build artifact;
no rebuild or reinstall is required for this launcher change. **No batch-device
timing, completed JIT initialization, or guest boot result is available.**

The next user log reached the USB forwarder and successful no-ack negotiation,
then stopped at `process connect`. Source review identified a launcher deadlock:
with synchronous debugger execution, LLDB's
[Platform connection path](https://github.com/llvm/llvm-project/blob/main/lldb/source/Target/Platform.cpp)
waits indefinitely for a process stop, while an unattached debugserver reports
`eStateConnected` until the subsequent attach request. The updated command uses
asynchronous connection only, consumes state events until `eStateConnected`
(bounded to 10 s), restores synchronous execution, attaches the known PID and
requires its stopped state. A parent 60 s connection/attach watchdog covers
blocking remote operations; it ends once attachment is verified and does not
limit the user's later VM selection. Python/shell syntax compilation and
independent source review passed. No runtime validation of this correction
was performed; no native app source/artifact changed.

VM deletion now has sidebar swipe/context and detail actions, named confirmation,
strict library-directory/symlink validation, background removal and a native
process-wide deletion reservation that blocks racing starts. Running machines
and stopped/failed machines still owned by the engine cannot be deleted until
app relaunch. Damaged configurations remain visible for deletion. Original ISO
sources, other machines, shared files and bundled firmware are preserved by the
deletion path. This is source/build evidence only; no existing user VM was
deleted during implementation.

Implemented the native iPad library/session, staged non-overwriting media
imports, persistent validated configuration, hardware input, Pencil pointer
input and viewport zoom. Options map to existing engine facilities with explicit
additions for read-only primary disk, microphone capture gating, presentation
rate and one loopback TCP forward. The optional Windows cleanup no longer
invokes the legacy helper that disabled security services and mitigations.

Normal creation now accepts only the user's Windows ARM64 ISO plus disk
capacity. The app supplies firmware, clones private NVRAM, creates a sparse
writable disk and a FAT16 `Autounattend.xml` disk, and mounts the ISO through a
new USB MSC/BOT DVD device using real guest I/O. Imports are staged in a new
directory; existing VMs are preserved. Automatic partitioning targets only the
new app-marked blank primary disk. The answer LUN is removed after partitioning
on warm reboot and is not attached to a nonblank target on later app launches.
The answer chooses the ISO's first image and accepts its setup EULA; product
licensing and normal account/OOBE screens may still require user input.

The app now links a real software TPM 2.0 using libtpms, with genuine FIFO/TIS
for the bundled firmware and CRB plus `MSFT0101`/TPM2 ACPI discovery for Windows.
Each VM has its own persistent NV state and an outer binding marker; damaged
or missing established state is preserved/rejected instead of manufacturing
replacement keys. The firmware package enables its TPM2/measurement components
in source. This is not hardware-backed TPM attestation or proof of guest TPM
recognition, measured boot, key persistence or BitLocker recovery. Windows Setup
may reject other platform requirements, and some ISOs may request a boot keypress.
No TPM/Secure Boot requirement bypass
or security-disabling registry changes were introduced. The USB and unattended
paths compile, but cannot be presented as a proven automatic installation.

The TPM/input milestone Release app links `TPMLIB_Process` and its actual CRB/FIFO
device implementation; its `TPM/` resources include dependency provenance,
full licenses and the entropy-failure patch. A fresh local launch-symbol
manifest was generated by read-only Mach-O parsing. Signing/package metadata
remains limited to the same seven registered devices. That milestone's log is
`build/logs/ios-app-build-tpm-input-signed.log`; no debugger, simulator, VM or
test was executed. Physical keyboard connection now leaves actual F1–F12 in
an onscreen row and hides the remaining software keyboard. RAM accepts any
whole MiB value within the 4096 MiB minimum, physical headroom and board-map
bounds, with exact reservation matching on startup. These are source/build
results, not device validation.

No tested iPad/iPadOS runtime matrix exists. Memory admission is conservative
policy, not proof that a model can boot Windows or avoid process termination.
Pencil pressure/tilt/eraser/Windows Ink pen identity require a future digitizer
device/report implementation; a guest driver alone cannot add that path.
Full engine teardown is absent, so another VM session requires app relaunch.
The latest display/network build adds a VirtIO GPU 2D backend and the pinned
Windows ARM64 NetKVM/viogpudo packages. The readonly driver medium is attached
as LUN2 even without an installation ISO. Fresh guarded setup copies drivers
through the WindowsPE configuration-set path and attempts the official helper
service installation during specialize. Failures are logged without aborting
Windows setup; existing VMs run the included installer as administrator once.
No Windows executable was run on this Mac. Preferred EDID/config-change events
and the official guest service support dynamic modes; actual native/Windows
resolution changes remain unverified. The GPU subsystem compatibility ID keeps
the pinned firmware's BLT-only GOP out of the boot path, preserving RAMFB.
Signed packaging and fresh local Mach-O launch metadata were prepared after
the build; no debugger or device attachment was performed.

Snapshots, suspend, accelerated 3D, arbitrary CPU models, bridged network and
UTM bundle import are not exposed as working features.

Install and explicitly launch using the procedure in
[IPAD_INSTALLATION.md](IPAD_INSTALLATION.md). The original upstream screenshots
and speed/hardware claims are not verification evidence for this update.
