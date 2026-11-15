# WindowsiOS verification report

Date: **2026-11-15**, America/Toronto. Target: **Windows 11 24H2 ARM64**,
confirmed by the user. Branch: `codex/ipad-24h2-build`.
Initial universal-app implementation commit: `69b2e7e`. This report now covers
the ISO-only setup correction `01b9340`, startup/deletion correction `99dbef2`,
and rebuilt artifacts.

## Verification scope

The user explicitly limited work to making the application build and prohibited
tests/debugging/VM execution on this Mac. After that instruction, verification
was limited to compilation, source inspection and artifact packaging/signature
inspection. No simulator, app, guest, debugger or performance workload was run.
Baseline core regression checks had already completed before that instruction;
they do not validate the subsequently added app/device changes.

## Evidence

| Deliverable/check | Result | Evidence and limit |
| --- | --- | --- |
| Native ARM64 iOS engine archive | **COMPILED** | `build/ios/libwinvm.a`, included in final signed app build. |
| Universal Swift/Objective-C/native application | **COMPILED** | `build/logs/ios-app-build-jit-delete-signed.log` ends with `BUILD SUCCEEDED`; includes startup guard, deletion, ISO wizard and USB optical transport. |
| Xcode Debug configuration | **COMPILED** | `build/logs/ios-app-build-jit-delete-debug.log` ends with `BUILD SUCCEEDED`; generic arm64 device build only, not app/debugger execution. |
| iPad device-target compilation | **COMPILED** | Generic `iphoneos` arm64 build; bundled `UIDeviceFamily` includes 2. No device run. |
| Duo/iPhone device-target compilation | **COMPILED** | Same universal arm64 artifact includes family 1; manual posture layout retained. Future hinge API excluded by SDK guard. No Duo run. |
| iOS dependencies | **COMPILED** | libffi 3.5.0, GLib 2.83.0, libslirp 4.9.1 and linked dependency archives staged in `ios/deps/`. |
| Signed app/IPA | **BUILT, SIGNATURE CHECKED** | `distribution/WindowsiOS.app`, `distribution/WindowsiOS-development.ipa`; `codesign --verify --strict` succeeded; IPA has `Payload/WindowsiOS.app`. |
| Build metadata | **RECORDED** | `distribution/BUILD_INFO.json`: arm64, iOS minimum 17.0, SDK 26.5, Xcode 26.6 (17F113), families [1,2]. |
| Bundled UEFI/variable template | **PACKAGED, HASHES CHECKED** | Matched 64 MiB `Firmware/code.fd` and `vars-template.fd` included in signed app. Pinned Debian EDK2 2025.02-8+deb13u1 package; manifest records hashes. Full licenses/provenance included. This proves packaged bytes, not firmware execution. |
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
4452465386d9fbf19088ec8d4df720c2450d053c3fe0d39d6905cad333085211
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

The engine has no virtual TPM. Windows Setup may reject that platform, and
some ISOs may request a boot keypress. No TPM/Secure Boot requirement bypass
or security-disabling registry changes were introduced. The USB and unattended
paths compile, but cannot be presented as a proven automatic installation.

No tested iPad/iPadOS runtime matrix exists. Memory admission is conservative
policy, not proof that a model can boot Windows or avoid process termination.
Pencil pressure/tilt/eraser/Windows Ink pen identity require a future digitizer
device/report implementation; a guest driver alone cannot add that path.
Full engine teardown is absent, so another VM session requires app relaunch.
Snapshots, suspend, accelerated GPU, dynamic guest resolution, arbitrary CPU
models, bridged network and UTM bundle import are not exposed as working features.

Install and explicitly launch using the procedure in
[IPAD_INSTALLATION.md](IPAD_INSTALLATION.md). The original upstream screenshots
and speed/hardware claims are not verification evidence for this update.
