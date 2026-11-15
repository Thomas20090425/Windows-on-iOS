# WindowsiOS on iPad — Windows 11 24H2 ARM64

This is a native SwiftUI/UIKit application linked to this repository's ARM64
translation engine, virtual NVMe/USB/network/audio devices and Metal display.
The current work is **build-verified only**. No iPad model or iPadOS release has
been verified to boot Windows in this session. See [VALIDATION_REPORT.md](VALIDATION_REPORT.md).

## Hardware and operating system

- Physical ARM64 iPad, conservatively requiring at least 8 GB physical RAM.
  The application admits 4–4.5 GiB guest RAM only after reserving 3 GiB of
  physical headroom; this policy does not guarantee immunity from Jetsam.
- Deployment target: iPadOS 17.0 or later. This is an SDK/build requirement,
  **not** a tested runtime compatibility list. JIT/TXM behavior is device and
  OS dependent. There are currently no verified iPad/OS combinations.
- iPhone support remains restricted at launch to the repository's Duo model
  identifier `iPhone19,4`. Other iPhone models are rejected. This session has
  not independently verified that hardware or its upstream boot claims.
- Apple Pencil and mouse/keyboard are optional; Pencil requires a compatible
  iPad/Pencil pairing. Hover additionally requires hardware that exposes it.
- Supply only your licensed **Windows 11 24H2 ARM64 installation ISO**. UEFI
  firmware and its variable-store template are included with the app.
- Select a Windows disk capacity from 64 to 512 GiB. The app creates a sparse,
  writable disk on the iPad; it grows as Windows writes data. Creation requires
  free storage for an app-private ISO copy plus 32 GiB of installation headroom
  and setup files. That admission check does not reserve the disk's full future
  capacity, so keep enough free storage for Windows and its updates.

## Build and signing

Use an Apple Silicon Mac with full Xcode, its iOS SDK, XcodeGen, Homebrew build
tools (`meson`, `ninja`, `pkg-config`, `libslirp`, `gettext`) and Python 3.
The compiled artifact was built with Xcode 26.6 / iOS SDK 26.5.

From the repository root:

```bash
JOBS=2 ./scripts/build_ios_app.sh
```

This downloads/checksums the pinned redistributable EDK2 firmware, compiles
dependencies, the native iOS archive and a generic arm64 device app into
`distribution/WindowsiOS.app`. The firmware, matching variable-store template,
licenses and provenance are bundled in the app's `Firmware` folder. No Windows
media is downloaded or bundled. The build does not run tests, simulators,
debuggers, or a VM. An unsigned build cannot be installed directly.

For development signing, use your own team and a profile registering your iPad:

```bash
DEVELOPMENT_TEAM=YOUR_TEAM_ID \
JOBS=2 ./scripts/build_ios_app.sh
```

With a matching local development identity and profile, this also creates
`distribution/WindowsiOS-development.ipa`. The supplied development IPA is
limited to devices included in its embedded profile; it is not an App Store or
universal sideload package. Do not commit provisioning profiles, certificates,
private keys or Windows media. Use Xcode to provision your own iPad if needed.
Automatic signing was used for the supplied artifact. Set
`PROVISIONING_PROFILE_SPECIFIER` only for a manually managed profile; Xcode
rejects Xcode-managed profiles when forced into manual signing mode.

## Install the app and import your Windows ISO

1. Pair your iPad with Xcode, trust the Mac and enable Developer Mode as required
   by the device. Register it in your development provisioning profile.
2. Build/sign, then explicitly install the app:

   ```bash
   ./scripts/install_on_device.sh DEVICE_ID distribution/WindowsiOS.app
   ```

3. Open WindowsiOS on the iPad and choose **New Machine**. Enter a name, choose
   the Windows disk capacity and tap **Import Windows ISO and Create**. Select
   your Windows 11 ARM64 `.iso` using the native file picker. An x64 ISO, ESD,
   VHDX or prepared raw disk is not the installation ISO expected by this flow.
   The app checks the optical-disc descriptor; it cannot establish that the
   supplied Windows edition is boot-compatible without actually booting it.
4. Keep WindowsiOS open while it imports the ISO. The app creates these files
   privately and publishes the machine only when preparation succeeds:

   | File | Automatically supplied or created by the app |
   | --- | --- |
   | Bundled `Firmware/code.fd` | Read-only EDK2 ArmVirtQemu firmware |
   | `vars.fd` | Private writable copy of the matching bundled UEFI variable template |
   | `windows11.img` | New sparse writable Windows disk at your selected capacity |
   | `installer.iso` | Read-only app-private copy of your selected ISO |
   | `setup-support.img` | Small FAT answer disk for automatic Windows partitioning/install |
   | `installation-created.json` | Marker restricting automatic answers to the new app-created blank disk |

   You do not find, download or import firmware or a variable store yourself.
   Existing VMs and disks are not overwritten.
5. Set the desired per-machine options before starting. Choose 4 GiB initially;
   4.25/4.5 GiB depend on both host admission and the JIT-time RAM reservation.
6. Initialize JIT using a compatible helper. **Xcode Run alone is not a JIT
   helper.** A normal debug attachment now returns a setup message without
   emitting custom allocation/probe breakpoint instructions. To use a Mac,
   stop the ordinary Xcode debug session and explicitly run:

   ```bash
   ./scripts/launch_on_device.sh DEVICE_ID me.ammaar.windowsios
   ```

   The launcher reads local symbols from `distribution/WindowsiOS.app` by
   default. That local app must match the build installed on the iPad. To use
   the packaged development build, install and launch the same local bundle:

   ```bash
   ./scripts/install_on_device.sh DEVICE_ID distribution/WindowsiOS.app
   ./scripts/launch_on_device.sh DEVICE_ID me.ammaar.windowsios distribution/WindowsiOS.app
   ```

   The default Mac transport batches 128 JIT page writes before collecting
   their replies. Its first launch installs pinned `pymobiledevice3==11.55.1`
   dependencies in `work/mac-jit-venv`, without changing system Python or
   requiring StikDebug. It uses a USB userspace developer tunnel and two
   loopback-only connections. Keep the device connected, unlocked and trusted.
   The launcher resolves the selected CoreDevice identifier to its hardware
   UDID; it never picks another attached device automatically. If Xcode omits
   that field, set `WINIOS_DEVICE_UDID` to the device's UDID from Xcode's Devices
   window. Local setup can also be prepared separately without opening a device:

   ```bash
   ./scripts/prepare_mac_jit.sh
   ```

   The launcher connects to the fresh debugproxy asynchronously, waits for its
   connected state, then attaches synchronously to the exact launched PID.
   Startup connection/attachment is limited to 60 seconds and prints each
   phase. Once attached, it waits for you to choose a VM and tap Start without
   that startup deadline. A previous launcher could stall at `process connect`
   after no-ack negotiation because it waited for a process stop before the
   attach request was sent. Updating the Mac scripts fixes that ordering; no
   app rebuild or reinstall is required. Stop the old launcher and fully close
   WindowsiOS before retrying.

   If you installed a Debug build from Xcode, supply that exact app instead:

   ```bash
   APP_PATH="/path/to/the/installed/WindowsiOS.app" ./scripts/launch_on_device.sh DEVICE_ID
   ```

   Keep the entire `.app`, including `WindowsiOS.debug.dylib` when present.
   Xcode Debug can put JIT symbols in that dylib rather than the executable.
   The launcher checks local Mach-O metadata before launching, then matches
   device image UUIDs before applying image-specific ASLR relocation. If the
   Debug image is not loaded at the initial stopped launch, it waits at app
   bootstrap before arming JIT. It does not guess addresses across builds.

   Alternatively, use **Enable JIT on Device** in the library/session with
   StikDebug installed and configured. Return to WindowsiOS and tap Start after
   the helper attaches. Only one debugger can own the process; detach/stop a
   normal Xcode session before using StikDebug. If StikDebug cannot open, the
   app reports that and points to the Mac helper.

   **Measured baseline:** this user's connection took 24.4 s for 316 serial
   page commands, projecting over 30 minutes. The new Mac proxy owns its
   connection and pipelines page commands rather than invoking LLDB once per
   page. Its actual preparation time and guest boot remain device-unverified.
   No fixed speedup is promised. The transport approach follows the batching
   in [StikDebug's native preparation](https://github.com/StikDebug/StikDebug/blob/f9c1f46fad389e6f46466777808eca99e9426c81/StikDebug/JSSupport/JSDebugSupport.swift#L89-L150),
   using [pymobiledevice3's loopback debugserver forwarding](https://github.com/doronz88/pymobiledevice3/blob/v11.55.1/pymobiledevice3/cli/developer/debugserver.py#L56-L99)
   on the Mac. Stop an old launcher with Control-C and fully close WindowsiOS
   before starting a fresh session with the updated command.

7. The helper launches the app stopped and attaches to the **iPad process**.
   Select the machine and tap **Start Windows** on the iPad while the helper is
   active. iPad JIT allocation waits until this selection, so the reservation
   uses that machine's memory setting. The helper services known JIT traps and
   detaches; unknown stops are left stopped and reported as errors. Updated
   helpers write and read back an explicit readiness word before resuming the
   app. Keep the helper script and installed app from the same build.

   During JIT preparation, Terminal reports acknowledged pages, covered MiB,
   percentage, elapsed time and an ETA based on observed packet latency. The
   default prepares every 16 KiB page using a one-byte debugger write, in batches
   of at most 128. A 384 MiB region has 24,576 pages, so the data payload is
   24,576 bytes. Every page must return exactly `OK`. The proxy permits batching
   only after successful no-ack negotiation and an observed target stop. It
   refuses protocol compression to keep page acknowledgements inspectable;
   interruptions, unexpected replies or timeouts close the connection. The
   app's RX execution check is retained. The app stays paused during this stage. The
   helper disables external/background symbol lookup for its own LLDB session
   and uses a nearby UUID-matched local dSYM when available. No persistent
   debugger preferences are changed. A single blocked debugger operation can
   still delay progress output; unchanged counters for several minutes should
   not be treated as proof that Windows is booting.

   If the USB tunnel cannot be established, the original Xcode transport is
   available explicitly:

   ```bash
   WINIOS_JIT_TRANSPORT=xcode ./scripts/launch_on_device.sh DEVICE_ID me.ammaar.windowsios distribution/WindowsiOS.app
   ```

   This fallback defaults to a bounded comparison of 1 MiB tuned bulk writes
   with eight serial page writes, then prepares the entire region with the
   observed faster method. It remains serial and can still be slow. Within
   that fallback, `WINIOS_JIT_PREPARE=pages` or `bulk` forces a method for
   diagnostics. The old bulk baseline projected about 22 minutes; packet-size
   tuning is not a demonstrated fix. A batch-transport failure never silently
   falls back on a partially prepared session. Fully close the app before retrying.
8. The firmware boots the ISO through the virtual USB mass-storage optical
   drive. Windows Setup uses the generated answer disk to partition the new
   Windows disk and install **image index 1**, the first Windows edition on the
   ISO. Setup may request a product key/license, language or account details
   inside the guest; no user account or credentials are preconfigured.
   Optical installation and the NVMe system disk use Windows inbox driver
   paths; no custom optical driver is a creation prerequisite.

The automatic answer includes Windows Setup EULA acceptance for the requested
installation. It does not add registry requirement bypasses, disable security
features, or embed a product key. It is attached only to an app-marked blank
target. Startup and warm-reset guards remove the automatic answer path after
the primary disk is partitioned, preventing repeat automatic formatting of an
installed VM. The primary disk remains writable throughout installation.

**Installation remains runtime-unverified.** This engine does not implement a
TPM, and Windows Setup may reject its hardware requirements or encounter other
firmware/device limitations. Bundling Secure Boot-capable EDK2 firmware and a
Microsoft-enrolled variable template does not prove that guest Secure Boot or
Windows 11 platform compliance works on this virtual hardware. No requirement
bypass is silently applied to turn such a rejection into a successful install.

These install and launch commands are procedures for the device owner; they
were not executed during this build-only session. `launch_on_duo.sh` remains
available for the original Duo workflow. With SDKs declaring the original
`UIHingeInteraction` API, enable `WINIOS_HINGE_SDK` in Swift compilation
conditions; the installed SDK does not declare that API, so its observer is
guarded and the original manual posture controls remain available.

## Advanced: existing prepared installations

The ISO-only flow above is the normal setup path and does not require a Mac-side
Windows provisioning stage. Existing `Documents/Machines/Win11` installations
can still be discovered. Advanced disk import accepts prepared `.img`/`.raw` or
`.hvsparse` primary disks and an optional read-only `secondary.img`; these
controls are hidden for machines managed by automatic ISO installation.
Legacy per-machine `code.fd` firmware takes precedence when present; new
machines use the bundled firmware automatically. Existing variable stores and
disks are preserved rather than reset or replaced.

The legacy Mac provisioner and `hvsparse` tool remain available for existing
workflows. They are not prerequisites for ISO setup inside the app. The optional
`optimize_windows_lite.py` preserves security/update/mitigation defaults and
does not invoke the old security-disabling `opt_hive_arm64.exe` helper. No
performance benefit has been measured for that cleanup profile.

## Delete an old virtual machine

Swipe left on a VM in the library, long-press it, or use **Delete Virtual
Machine…** in machine details. Confirm the named VM to remove its private
disk, imported ISO copy, NVRAM and configuration. The original source ISO,
other VMs, shared files and bundled firmware are kept. Removal runs in the
background, with new starts and file operations held until it finishes.

A running VM cannot be deleted. A stopped or failed VM whose engine still owns
its disk handles is also protected; fully close and relaunch WindowsiOS first,
then delete it. This avoids deleting storage still retained by the engine.
An invalid `configuration.json` remains visible as an incomplete machine so it
can be deleted through the same confirmation flow.

## Controls and configuration

- Physical keyboard: HID key-down/up, modifiers, arrows, Escape, function keys
  and guest shortcuts. Command maps to the Windows key by default; optionally
  map it to Control. Some iPadOS-reserved shortcuts cannot reach the guest.
- Mouse/trackpad: absolute pointer, left/right/middle buttons, dragging, and
  horizontal/vertical scrolling. Windows handles double-click timing.
- Touch: tap/drag, long press or two-finger tap for right-click, optional relative
  trackpad mode and configurable sensitivity. Three-finger tap toggles controls.
- Pencil: precise/coalesced absolute positions, tip contact and dragging through
  the existing USB tablet path. Supported hover moves the pointer. **Pressure,
  tilt, eraser and Windows Ink pen identity are not implemented.** No custom
  driver is needed for basic tablet pointer input. Installing a driver alone
  cannot add pressure/tilt: a future host HID digitizer implementation is required.
- Pinch zoom: 1–3× host viewport; two-finger movement pans while zoomed. At fit
  scale, two-finger movement scrolls Windows. This does not change guest resolution.
- Software keyboard fallback sends US ASCII keystrokes. Unicode/IME composition
  and arbitrary clipboard paste are not implemented.
- CPU/RAM, primary disk read-only mode, optional second read-only NVMe disk,
  NAT, one loopback TCP port forward, shared-folder enablement, audio/microphone,
  30/60/120 Hz host presentation limit, input preferences and diagnostic logging
  are stored per machine. Detailed mapping: [UTM configuration review](docs/UTM_CONFIGURATION_REVIEW.md).
- Shared files live in `Documents/Shared` and use the existing guest WebDAV route
  `http://10.0.2.4/`. Only put files intended for the guest there. Sharing requires
  NAT enabled. NAT backend readiness does not prove guest driver connectivity.
- Read-only primary disks usually cannot run a normal Windows desktop requiring
  writes. This advanced legacy option is disabled for automatic ISO installation.
  It is a storage protection option, not a disposable snapshot.
- The app fits the guest framebuffer to the host window. Guest resolution is
  controlled by firmware/Windows; there is no SPICE dynamic-resolution agent.

## Lifecycle, limitations and troubleshooting

Use **Request Shutdown** or Windows Shut Down first. **Force Stop** can lose
unsaved work. Returning to the library keeps the active session running.
The engine lacks complete teardown; **close/relaunch the app before another VM
session or switching machines after shutdown**. Snapshots/suspend are unavailable.
Backgrounding flushes storage but does not preserve complete guest state;
iPadOS may suspend or terminate the app. Keep it foregrounded while working.

| Symptom | Next action |
| --- | --- |
| Cannot install | Rebuild with a matching development profile registering this iPad. |
| Waiting for JIT | Run the device launch helper, then tap Start on the iPad. A signed app alone does not enable JIT. |
| `EXC_BREAKPOINT` in `winios_brk.S` | The stopped instructions are the custom JIT protocol. Rebuild/reinstall the current app and use its matching helper. A normal Xcode Run attachment does not service that protocol; do not skip arbitrary breakpoint instructions. |
| LLDB cannot find `winios_jit_helper_token` | Use the updated launcher and the matching local `.app`. This error can mean absent LLDB metadata or an unloaded Debug dylib; it does not alone establish an old app. |
| App UUID mismatch | Set `APP_PATH` to the exact Xcode-built app installed on the device, or install `distribution/WindowsiOS.app` and launch using that same path. No address guessing is permitted. |
| Stuck at “Locating external symbol file” after RX allocation | Interrupt the old helper with Ctrl+C; if an LLDB prompt appears, type `quit`. Rerun the updated launcher, which limits symbol lookup to local metadata and prints JIT memory-transfer progress. That status is symbol discovery, not Windows boot. |
| Delete unavailable | Stop the VM and relaunch the app to release retained engine state. Wait for imports/extraction/deletion to finish. |
| JIT trap/allocation failure | Record the OS/model and helper error. This device/OS combination remains unsupported until verified. |
| Insufficient reservation | Relaunch, select supported memory before Start, and initialize JIT again. No sub-4-GiB fallback is used. |
| Missing bundled firmware | Rebuild/reinstall the app. Firmware preparation runs during the app build; no firmware picker is required. |
| ISO import fails | Choose the original Windows 11 ARM64 ISO and check free iPad storage. Failed creation removes only the new staging directory. |
| Windows Setup rejects requirements | The virtual platform has no TPM. Capture the guest error; no silent requirement or security bypass is applied. |
| Existing raw disk + archive | Raw disk takes precedence. Back up before managing files; extraction will not replace it. |
| Extraction error | Check free storage and archive integrity. Source archive and existing raw disks are retained. |
| No network | Check NAT backend diagnostics, port conflicts and the guest's ARM64 NetKVM driver. |
| No microphone | Enable guest audio and microphone, grant iPadOS permission, and check Windows input settings. |
| Stuck keys after focus change | Opening native settings/library releases held guest keys/buttons. Runtime behavior remains untested. |
| Need logs | Inspect `Documents/boot_status.txt`; optional instruction logging is verbose. Automatic screenshots are off unless `WINIOS_ALWAYS_SCREENSHOT` is explicitly set. |

No documented untethered JIT solution for this engine was established here.
The existing TXM trap protocol and ledger-exempt memory allocator are
OS-sensitive mechanisms, not a public portability guarantee. Apple's documented
[JIT entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit)
is listed for macOS; its existence does not establish iPad executable-memory
access. Apple's [increased-memory-limit entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)
also depends on device support and available memory. This build does not claim
either as an untethered solution. No jailbreak or host security-setting changes
were used.
