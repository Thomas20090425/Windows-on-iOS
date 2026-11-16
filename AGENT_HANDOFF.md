# WindowsiOS agent handoff

This is the portable continuation record for the iPad/Windows 11 work through
**2026-11-15**, implementation commit **`661b8ae`**, originally developed on
**`codex/ipad-24h2-build`**. The canonical development target is now **`main`**,
as requested by the user. Read [README.md](README.md) first for current setup,
[VALIDATION_REPORT.md](VALIDATION_REPORT.md) for evidence, and
[PROGRESS_LOG.md](PROGRESS_LOG.md) for the chronological record. Later commits
may update documentation without changing that implementation baseline.

## User instructions that continue to apply

- Target **Windows 11 24H2 ARM64**. The original “24H4” request was explicitly
  corrected to 24H2.
- **Build only on this Mac.** The user explicitly prohibited tests, debugging,
  profiling, simulator execution and VM execution because the Mac lacks the
  necessary processing power. Keep compiler concurrency at **`JOBS=2`**.
  Do not start an app, device session, LLDB helper or guest automatically. The
  user runs the Mac launcher and supplies its results.
- Normal setup must require **only the user's Windows installation ISO**.
  Bundle redistributable firmware, the matching fresh UEFI variable template,
  TPM dependencies and ARM64 network/display driver media in the app. Create
  the Windows disk from app-managed storage. Do not restore manual firmware
  or variable-store import as a normal setup step.
- Preserve the native iPad session and existing iPhone Duo interface. Pencil,
  physical mouse/keyboard, F1–F12, editable RAM allowance, networking and
  native/dynamic display modes are requested features.
- The user prefers the **Mac/computer JIT launcher**. StikDebug is an optional
  alternate, not the assumed next step.
- Treat implemented source, successful compilation, and device/guest behavior
  as separate evidence. Do not report unobserved boot, speed, driver trust,
  Internet access, input or resolution results as verified.

## Current result and boundaries

The latest universal arm64 device app compiles and packages with bundled UEFI,
software TPM 2.0, and official ARM64 VirtIO drivers. Native UI configuration is
connected to the engine; this is not a QEMU/UTM wrapper. UTM documentation and
configuration models were design references; no UTM source was copied. See
[the UTM mapping](docs/UTM_CONFIGURATION_REVIEW.md).

The iPad gate requires enough physical memory to reserve a 4 GiB guest while
retaining 3 GiB host headroom, making 8 GB or larger devices conservative
candidates. The original Duo model gate is `iPhone19,4`. These are source
policies, not a tested hardware compatibility list. Minimum deployment is
iOS/iPadOS 17.0; TXM/JIT compatibility remains device-dependent.

The engine still owns process-global state. After stopping/failing a VM,
**fully close and reopen the app before another VM, a changed RAM reservation,
or deletion of a machine whose handles remain owned**. There is no complete
in-process teardown, snapshot, suspend/resume, or safe live VM replacement.
Deletion has confirmation, path/symlink checks and engine-ownership guards.

## Architecture and source entry points

| Area | Files to read | Responsibility and implementation notes |
| --- | --- | --- |
| App and persisted configuration | `ios/Sources/WindowsiOSApp.swift`, `VMConfiguration.swift`, `VMViewModel.swift` | Native SwiftUI entry; validated per-VM `configuration.json`; backward defaults for new fields. Persisted settings are validated again at the native boundary. |
| Library and creation | `ios/Sources/VMLibraryView.swift`, `NewWindowsMachineView.swift`, `VMMachineSetup.swift` | ISO-only creation, 64–512 GiB sparse writable Windows disk, private NVRAM/media, settings, safe deletion. Advanced legacy imports remain available. |
| Installer answers | `ios/Sources/WindowsInstallationMedia.swift` | Private copy of the bundled FAT driver disk; reserved 64 KiB answer-file slot, FAT/LFN construction, fresh-target formatting guard, WinPE driver paths and specialize installer. Removing installation answers preserves driver access. Existing disks receive no formatting answers. |
| Session UI and input | `ios/Sources/IPadSessionView.swift`, `SessionView.swift`, `MetalDisplayView.swift`, `HardwareInput.swift`, `HingeSensorView.swift` | iPad/Duo presentation, UIKit/GC input, physical keyboard detection, F-key row, Pencil pointer, central pointer/button state, viewport reporting. |
| Native bridge | `ios/Sources/Native/winios_bridge.m`, `winios_bridge.h` | Device gate, exact RAM preallocation, VM options/start, TPM marker placement, preferred-resolution/debounce, display/input/status bridge. |
| Native JIT | `ios/Sources/Native/winios_jit.c`, `winios_jit.h`, `winios_brk.S`, `host/jit_region.c`, `host/enter.S` | Debugger readiness token, known BRK handshake, dual RW/RX mappings, retained RX execution self-checks, translated-code entry. |
| CPU translator | `core/`, especially `core/sysreg.c`, `core/cpu_model.h` | ARM64 translation, software MMU and guest system registers; shared truthful virtual CPU identity. |
| VM lifetime/board | `host/winvm.c`, `host/winvm.h`, `host/guest_memory.h`, `devices/winvirt.c`, `devices/winvirt.h` | Process-global engine, RAM/map bounds, device setup, disk/TPM/media ownership, reset/error handling, virtual ARM64 board. |
| Discovery and transport | `devices/acpi.c`, `devices/fdt.c`, `devices/virtio.c`, `devices/virtio.h` | ACPI/FDT CPU/device/TPM discovery; modern PCI VirtIO queues, reset and MSI-X. |
| Display | `devices/virtio_gpu.c`, `virtio_gpu.h`, `devices/fb_display.c`, `fb_display.h`, `devices/fb_metal.m` | VirtIO GPU 2D resources/backing/transfers/scanout/cursor/EDID/display events; framebuffer lifetime locking and Metal presentation. |
| Guest media | `devices/usb_storage.c`, `usb_storage.h`, `devices/xhci.c`, `xhci.h` | USB MSC: LUN0 Windows ISO, LUN1 guarded installation answers, LUN2 bundled drivers. Driver-only attachment works without an ISO. Existing xHCI HID keyboard/tablet remains the guest input path. |
| Software TPM | `devices/tpm_crb.c`, `tpm_crb.h` | Actual libtpms TPM 2.0 backend, Windows CRB and firmware FIFO/TIS frontends sharing one identity/state, locking, durable persistence and fail-closed error handling. |
| Network and sharing | `devices/virtio_net.c`, `host/net_slirp.c`, `host/share.c` | VirtIO network/MSI-X and libslirp NAT/DHCP/DNS; existing guest WebDAV share and loopback forwarding. |
| Build/resources | `scripts/build_ios_app.sh`, `build_ios_deps.sh`, `build_ios_tpm_deps.sh`, `prepare_firmware.py`, `prepare_windows_drivers.py`, `ios/project.yml` | Cross-build libraries, download/verify resources, archive engine, generate Xcode project, build/package app, record provenance. |
| Mac JIT transport | `scripts/launch_on_device.sh`, `_launch_mac_jit.py`, `jit_rsp_proxy.py`, `_lldb_txm_jit.py`, `jit_symbols.py`, `prepare_mac_jit.sh` | Owner-run launch, exact device resolution, owned USB/debugserver transport, batched page preparation, asynchronous connect/attach, UUID-matched local symbols. |

Configuration exposes 1–4 vCPUs; custom whole-MiB RAM; NAT; one loopback TCP
forward; sharing; speaker/microphone controls; input mapping/sensitivity;
30/60/120 Hz host presentation; resolution/follow-window settings; and native
diagnostics. Arbitrary CPU architecture/models, bridged networking, QCOW2/VHDX
conversion, live disk replacement, clipboard sync and USB device passthrough
are not implemented. Newly configured microphones default off.

## Input, RAM, CPU and display details to preserve

- RAM accepts any whole-MiB value from **4096 MiB** to the calculated device
  limit: physical MiB minus **3072 MiB**, additionally bounded before PCIe ECAM.
  The previous fixed ceiling/step is removed. A request must exactly match the
  reserved memory; it is never silently reduced. A changed reservation needs
  an app relaunch.
- Physical mouse buttons use GCMouse and a passive UIKit indirect-pointer
  observer. Held/external button masks are centralized so hover, scroll and
  delayed synthetic releases do not release a real held button. This fixes
  source paths for left/right/middle clicks; user confirmation remains open.
- Hardware F1–F12 generate actual HID usages `0x3a`–`0x45`. Detecting a
  physical keyboard hides the full software keyboard. A floating F keys button
  toggles the default-hidden row over the unchanged guest viewport; the typing
  keyboard remains separate. iPadOS may retain some system shortcuts.
- Apple Pencil currently provides pointer motion, hover where supported and
  tip/drag through the tablet path. **Pressure, tilt, eraser and Windows Ink
  digitizer reports are absent.** A guest driver alone cannot supply those
  missing host/HID reports.
- The guest consistently identifies as **Arm Cortex-A76 r4p1 (virtual)**,
  `MIDR_EL1=0x414fd0b1`, device-tree `arm,cortex-a76`. The nominal 3072 MHz is
  virtual counter accounting, not measured host speed. Do not restore Apple
  or Snapdragon marketing-name spoofing.
- Display choices are Native screen, Fit app window, 1280×720, 1920×1080,
  2560×1440 and 3840×2160. Native uses physical screen pixels/orientation;
  window mode uses viewport pixels. Preferred dimensions have a 640×480
  minimum and 4095-per-axis EDID limit. Rotation/resizing is debounced 250 ms.
  Guest Windows controls the active mode; its installed `vgpusrv` service is
  required to apply dynamic preferred-mode changes automatically.
- Firmware retains a linear RAMFB boot console (initially 800×600); the
  Windows VirtIO driver enables the later selected modes. GPU subsystem ID
  **`0x0010` is deliberate**: pinned EDK2's Virtio10 driver skips it instead of
  binding its BLT-only GOP. The Windows INF matches generic
  `VEN_1AF4&DEV_1050`. Do not change that ID to `0x1100`/the firmware's `>=0x40`
  range without resolving the firmware boot-console limitation.
- The bundled `UseVirtioDisplay.ps1` helper selects the identified connected
  VirtIO path as the sole active Windows desktop, disconnecting the fixed
  firmware desktop through CCD APIs. The driver installer copies it to Program
  Files, registers an HKLM Run command for interactive sign-in and applies it
  immediately outside Setup. Existing VMs need the updated installer once.
  `UseVirtioDisplay.cmd` on WINIOSDRVS applies the current-session repair alone.
  Do not disable/uninstall BasicDisplay or remove the boot RAMFB.
- GPU support is **2D scanout and cursor**, with Metal host presentation.
  Accelerated 3D/DirectX, Virgl and Apple GPU passthrough are absent.

## Bundled dependencies, provenance and licenses

The authoritative manifests are generated into the app and local
`distribution/BUILD_INFO.json`. Use these source documents when updating pins:
[firmware](docs/FIRMWARE_PROVENANCE.md), [TPM](docs/TPM_PROVENANCE.md),
[Windows drivers](docs/WINDOWS_DRIVERS_AND_DISPLAY.md), and
[third-party notices](THIRD_PARTY_NOTICES.md).

| Dependency | Pinned input | SHA-256 |
| --- | --- | --- |
| Debian `qemu-efi-aarch64` | `2025.02-8+deb13u1`; secure-boot code and matching Microsoft-enrolled variable template, 64 MiB each | `a00b2411a79c8aeafd95a7c868ac3cd1aab592f1af9fff965f02d81a625276ed` |
| libtpms | `0.10.2`, TPM 2.0 only | `edac03680f8a4a1c5c1d609a10e3f41e1a129e38ff5158f0c8deaedc719fb127` |
| OpenSSL | `3.5.9` LTS | `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a` |
| libtpms entropy patch | `scripts/patches/libtpms-0.10.2-entropy-fail-closed.patch` | `2a9a265c501b39a1955bff1d1c56dd90b275f5322d4314e8acb666b6fe1c75ab` |
| Official virtio-win RPM | `0.1.302-1`, ARM64 driver `100.103.104.30200`, dated 2026-07-22 | `2f58eea024e0221a873032761dc3ed3262409cd80860b7b27d3d5a0f206616c9` |

Other versioned dependencies are libslirp `4.9.1`, GLib `2.83.0`, libffi
`3.5.0`, and Mac helper `pymobiledevice3==11.55.1`. The libslirp build also
stages its libintl/PCRE2 dependencies. The older network dependency script uses
versioned URLs; do not describe all of those downloads as checksum-pinned.
The dependency recipe no longer consults optional local Husk reference
checkouts or stages unused StikJIT frameworks. A clean checkout uses the
tracked preparation scripts and their declared downloads.

Source retains **GPL-2.0-or-later**. The combined OpenSSL 3-linked iOS binary
uses its permitted **GPLv3** option; full GPLv3 and linking notices accompany
the app. Retain EDK2/component, libtpms, Apache-2.0 OpenSSL and virtio-win BSD
notices. Henge/Husk attribution and the optional StikDebug/StikJIT/idevice
notices are recorded in `THIRD_PARTY_NOTICES.md`. No proprietary Windows image
is bundled.

### TPM state and Windows drivers

Windows sees CRB at `0x090c0000` through ACPI `MSFT0101`/TPM2 start method 7.
Firmware sees genuine FIFO/TIS at `0x090d0000` through the device tree. Both
share one serialized libtpms backend and permanent identity. No PPI or IRQ is
advertised. EDK2 TPM build components are present; successful measured boot,
enrollment and BitLocker behavior have not been observed.

Per-VM TPM files use exclusive locking and atomic durable updates. Entropy
failure is fatal; no weak `rand()` fallback is allowed. Corrupt/unreadable
established state is rejected and preserved. An outer
`tpm-state-initialized` marker prevents silently replacing keys if the entire
`TPM/` directory disappears. Warm resets preserve permanent keys. **Back up
the Windows disk, UEFI variables, `TPM/` and that outer marker together** before
changing storage. This is a software TPM, with no Secure Enclave-backed guest
attestation.

The bundled 64 MiB FAT16 driver disk is labeled **WINIOSDRVS**. It includes
unmodified ARM64 NetKVM, viogpudo and official resolution helpers. Build-time
PE/INF/catalog metadata checks do not prove Windows signature acceptance or
successful installation. No signature-policy bypass or test certificate is
installed. New ISO setup attempts automatic driver staging and service
installation; failures are logged and do not abort OS installation.

For **existing VMs**, the owner opens WINIOSDRVS and runs
**`InstallDrivers.cmd` as administrator once**, then restarts Windows if
prompted. Packages/helpers are copied to `%ProgramFiles%\WindowsiOS Drivers`;
the log is `%ProgramData%\WindowsiOS\DriverInstall.log`. The official
`vgpusrv` service supplies dynamic resolution. NAT must be enabled; expected
addresses are guest `10.0.2.15`, gateway `10.0.2.2`, DNS `10.0.2.3`.
Backend/link readiness is not evidence of Internet traffic.

## Build, artifacts and owner-run procedures

The latest display/keyboard correction built in signed Release with two workers
on Xcode 27.2 / iOS SDK 27.2; log:
`build/logs/display-keyboard-overlay-build.log`. The current app/IPA and manifest
are in `distribution/`. Signature, IPA integrity, bundled helper/image hashes
and local JIT symbol metadata were checked. No guest/test/device execution.
The current artifact supersedes the older milestone table below; display
topology selection still requires the user's Windows confirmation.

The canonical public checkout is `main` in
[Thomas20090425/Windows-on-iOS](https://github.com/Thomas20090425/Windows-on-iOS).
The [main source ZIP](https://github.com/Thomas20090425/Windows-on-iOS/archive/refs/heads/main.zip)
includes the app/engine source, configuration and dependency preparation
scripts. The Xcode project is generated from tracked `ios/project.yml`.
Generated projects, downloaded firmware/drivers/libraries and compiled products
remain ignored because the build recreates them; no Windows media or signing
identity is published.

For a new checkout, the root **`Build.command`** is the double-click build entry
point. Full Xcode/iOS SDK and Homebrew must already be installed. It checks
Xcode, installs missing Homebrew build prerequisites and calls
`scripts/build_ios_app.sh`, with two workers by default. First use needs
Internet access. Default output is unsigned; own development signing is still
needed to install. It does not execute tests, launch the app/VM or attach a
debugger. The bootstrap is source-reviewed; do not treat the historical
Release artifact below as evidence of a fresh bootstrap run.

Use an Apple Silicon Mac with full Xcode/iOS SDK, XcodeGen, Python 3 and the
cross-build tools described in [IPAD_INSTALLATION.md](IPAD_INSTALLATION.md).
The dependency scripts use Meson, Ninja, pkg-config, gettext, Autoconf,
Automake, Libtool, Perl and `bsdtar` for archive extraction. Host libslirp and
7-Zip are not prerequisites for this app build; iOS libslirp is cross-compiled
from its declared download. Build inputs and outputs are cached locally.
Network downloads may be substantial. The double-click entry point records
its log in `build/logs/one-click-build.log`.

From the repository root, compile only:

```sh
JOBS=2 ./scripts/build_ios_app.sh
```

That default creates an unsigned generic-device Release artifact. For a
development-signed build, use the owner's own Apple team/profile:

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID JOBS=2 ./scripts/build_ios_app.sh
```

`CONFIGURATION=Debug` is supported by the script; do not assume that today's
Release evidence also verifies all latest features in Debug. The normal
script prepares firmware/drivers/TPM libraries, builds the native archive,
generates the Xcode project, performs a generic arm64 device build and
packages resources/signing metadata. It does not run a guest or tests.

Latest recorded artifact, **2026-11-15 20:21 UTC**:

| Field | Recorded value |
| --- | --- |
| Implementation | `661b8ae` |
| Build | Release, arm64, universal device families 1 and 2, deployment 17.0 |
| Toolchain | Xcode 26.6, build 17F113; iOS SDK 26.5 |
| Result | Signed development app and IPA; compilation/packaging only |
| Local output | `distribution/WindowsiOS.app`, `distribution/WindowsiOS-development.ipa`, `distribution/BUILD_INFO.json` |
| IPA SHA-256 | `5251bfa1a41465efcb1e7898412bdabd8effc79bc1097aaceb2c918bd9214d70` |
| Driver-image SHA-256 in this artifact | `fa44478a281bc1401bdd580bb5f44a9c03f50f74483e5ffbd113b6dca43ecb10` |
| Local build evidence | `build/logs/ios-app-build-network-display-signed.log`: `BUILD SUCCEEDED` |
| Runtime evidence | Not run: no test, app, simulator, debugger, device or VM execution |

The signed artifact is limited by its development provisioning profile; it is
not a universally installable distribution. Artifact hashes change with a new
build/signature. **The app/IPA, logs, generated symbols, firmware binaries,
driver images and static dependencies are ignored build outputs, not files
available from a clean GitHub checkout.** Rebuild on another checkout.
`build/`, `work/`, `ios/deps/`, `distribution/` and generated Xcode projects
are ignored. Never commit Windows media, device identifiers, provisioning
profiles, credentials, compiled dependency payloads or local diagnostic logs.

The following are **owner-run device actions**, documented for the user;
they are not part of build-only verification. Replace `DEVICE_ID` and
`APP_PATH` with the owner's identifier and matching signed local `.app`:

```sh
./scripts/install_on_device.sh DEVICE_ID APP_PATH
./scripts/launch_on_device.sh DEVICE_ID me.ammaar.windowsios APP_PATH
```

The usual `APP_PATH` is `distribution/WindowsiOS.app`. Both helpers default to
that path when omitted; the launcher also defaults its bundle identifier.
Install the exact matching build before launch. A stale installed app or
different Debug dylib cannot share the current local symbol manifest.
The owner then selects a VM and taps Start to request JIT preparation.

## Mac JIT: what happened and what remains unknown

The original `EXC_BREAKPOINT` was at the intentional JIT BRK protocol. Startup
now requires a read-back-verified helper token, not just `CS_DEBUGGED`, before
those traps are used. The helper matches exact trap PCs/opcodes and does not
continue unrelated stops. Protocol: BRK `0x69` probe returns `0xE0000069`;
BRK `0xf00d` with `x16=1` prepares the region and `x16=0` requests detach.
The engine still reserves a **384 MiB** dual-mapped JIT region and retains
native RX execution self-checks. Do not bypass those checks to make startup
appear successful.

The user's earlier serial paths were genuinely slow:

- Full-region write: **21 MiB in 72.9 seconds**, projecting about **22 minutes**
  for 384 MiB under that observed connection.
- One-byte-per-page, serial acknowledgements: **316/24,576 pages in 24.4
  seconds**, projecting roughly **31–32 minutes**. Reducing payload alone did
  not remove round-trip latency.

The current default is **`WINIOS_JIT_TRANSPORT=batch`**. It sets up the local
`work/mac-jit-venv`, pins pymobiledevice3, resolves the exact CoreDevice ID to
the matching hardware UDID without guessing the first device, and owns its
localhost USB/debugserver proxy. It does not steal an LLDB-owned connection.
After no-ack negotiation and an observed stop, the proxy sends up to **128
one-byte page writes** before draining exactly that many `OK` responses:
24,576 pages become 192 batches. Region requests are divided into 8 MiB chunks
(four batches). Each batch has a 60-second response deadline; LLDB packet
timeout is 300 seconds and is configured before connection. Compression is
declined, debugserver's no-ack dummy checksums are handled, and unexpected
responses, stops, leftovers or timeout close the connection rather than
claiming preparation succeeded.

An earlier batch run stalled during synchronous `process connect` before
attach: LLDB waited indefinitely for the remote process to stop. Commit
**`f82c1aa`** changes this to asynchronous connect, a bounded connected-state
wait, restored synchronous operation and explicit attachment to the known
PID. The launcher also has a **60-second connect/attach watchdog**; after
attachment it can legitimately wait for the user to tap Start.

**No user timing or successful completion has been reported for the corrected
batch path.** There is no verified post-fix RX self-check, detach or Windows
boot result. The first continuation task is to get the user's newest launcher
output for the matching installed app, not to assert a speedup or tell them
to wait another half hour.

`WINIOS_JIT_TRANSPORT=xcode` retains the older Xcode attach route. Its
`WINIOS_JIT_PREPARE=auto` calibration selects bulk/page preparation from
observed latency; `pages` and `bulk` overrides remain available. These are
fallbacks, with no new measured speed claim. Local Mach-O UUID matching in
`jit_symbols.py` and session-local suppression of external symbol discovery
avoid stale symbol addresses and lengthy background lookup; never guess an
ASLR slide. Optional StikDebug instructions are in the installation guide.

## Implementation milestones

These commits are the durable source record; documentation-only commits are
also present in history. Use `git show COMMIT` to inspect a particular change.

| Commit | Subject |
| --- | --- |
| `69b2e7e` | Add native iPad sessions, Pencil input, and validated VM configuration |
| `01b9340` | Add ISO installation media, bundled UEFI, and in-app Windows disk creation |
| `99dbef2` | Gate JIT breakpoints on helper readiness and add safe VM deletion |
| `6c5a5e7` | Resolve device JIT addresses from UUID-matched local app images |
| `226a42e` | Avoid external symbol discovery and report JIT preparation progress |
| `7007144` | Prepare JIT with sparse acknowledged page writes instead of full-region uploads |
| `e19d30b` | Record serial JIT latency and document batched StikDebug setup |
| `9182936` | Batch Mac JIT page preparation through owned USB transport |
| `f82c1aa` | Avoid synchronous LLDB connect deadlock before device attach |
| `bde8116` | Add persistent software TPM2 and improve RAM and hardware input |
| `661b8ae` | Add ARM64 driver media, VirtIO display and dynamic resolution support |

## Open continuation work

1. Obtain the user's latest Mac launcher log after installing the matching
   app. Establish whether corrected connect/attach completes, then whether
   batch page preparation, native RX checks and detach finish. Record actual
   elapsed time and failure stage. The user performs device execution.
2. Follow the next user-reported failure through UEFI, ISO/24H2 setup and
   fresh-disk guards. TPM firmware/Windows handoff, enrollment, durable keys,
   warm reset, NVRAM and BitLocker recovery remain device-unverified.
3. Confirm Windows driver trust/installation, existing-VM installer behavior,
   NetKVM Internet access, 2D display, preferred/native/dynamic modes and the
   resolution service. A ready backend is insufficient evidence.
4. Confirm physical left/right/middle clicks, held buttons, hardware F-keys,
   Pencil pointer, keyboard-row presentation and memory pressure on the
   owner's device. Current source fixes are not device validation.
5. Preserve disks/TPM identity and the app-relaunch requirement. Full teardown,
   snapshots, suspend/resume, 3D acceleration and Ink digitizer reports are
   separate unfinished work, not hidden capabilities.

Do not start a broad runtime-validation campaign on this Mac. Continue from
the user's supplied result or requested feature, with build-only checks for
new code and documentation updated to match the actual evidence.

## Copy-paste prompt for another agent

```text
Continue WindowsiOS on main (the canonical branch). First read README.md,
AGENT_HANDOFF.md, VALIDATION_REPORT.md and PROGRESS_LOG.md; inspect current
git status/log so later work is preserved. The implementation baseline is
661b8ae, with native iPad/ISO-only setup, bundled UEFI/TPM/ARM64 drivers,
custom RAM, mouse/F-key fixes, NAT and VirtIO GPU 2D/native/dynamic modes.

Persistent instructions: Windows 11 24H2 ARM64; build only with JOBS=2 on
this weak Mac. No tests, debugger, simulator, profiling, app/device/VM launch
unless the user explicitly changes that instruction. The user runs the Mac
JIT launcher. Do not require firmware/vars imports or claim verified guest
results. Pencil is pointer-only; GPU is 2D, not accelerated 3D. Preserve TPM
state with disk/NVRAM, and the current full-app-relaunch requirement.

The old serial JIT baseline was 22–32 minutes. Owned batched USB preparation
and the f82c1aa asynchronous connect fix exist, but no post-fix user timing,
detach or Windows boot result has been reported. Obtain the user's newest
launcher/device result for the matching installed build, or their next
feature goal, before choosing runtime work. Do not launch it yourself.
Build outputs and logs are ignored, so another checkout must rebuild its
own signed app. Build.command is the download/double-click entry point after
full Xcode and Homebrew are installed; it defaults to two workers and an
unsigned compile. Read provenance/license docs before changing bundled pins.
Document the exact change, compile evidence and remaining runtime limits.
```
