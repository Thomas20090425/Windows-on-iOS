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
- Keep enough free storage for the prepared disk, imported archive, extraction
  and Windows updates. A sparse disk's logical capacity differs from its
  allocated storage usage. Import keeps the source archive for recovery.

## Build and signing

Use an Apple Silicon Mac with full Xcode, its iOS SDK, XcodeGen, Homebrew build
tools (`meson`, `ninja`, `pkg-config`, `libslirp`, `gettext`) and Python 3.
The compiled artifact was built with Xcode 26.6 / iOS SDK 26.5.

From the repository root:

```bash
JOBS=2 ./scripts/build_ios_app.sh
```

This compiles dependencies, the native iOS archive and a generic arm64 device
app into `distribution/WindowsiOS.app`. It does not run tests, simulators,
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

## Prepare your Windows installation

Supply your own licensed **Windows 11 24H2 ARM64** installation. The existing
provisioner expects `work/downloads/Win11_24H2_ARM64_en-us.esd`, EDK2 ArmVirtQemu
firmware at `work/code.fd`, and the required ARM64 NetKVM driver files.
Review `scripts/provision_windows_arm64.py` before using it on a capable Mac.
Provisioning runs a VM; it is separate from the compile-only app build.

The app consumes an already prepared raw system disk, not an installer ISO,
VHDX or QCOW2 file. Create/convert/provision the disk on a capable host first.
No Windows installation media, firmware, or proprietary guest driver is included
in the distributed app. Required per-machine files are:

| File | Purpose |
| --- | --- |
| `code.fd` | EDK2 ArmVirtQemu UEFI firmware, read-only |
| `vars.fd` | Persistent UEFI variable store, writable |
| `windows11.img` or `windows11.hvsparse` | Prepared Windows ARM64 system disk |
| `secondary.img` (optional) | Additional raw disk attached read-only |

`build/hvsparse pack SOURCE.img OUTPUT.hvsparse` packages raw sparse disks for
transfer, if you have built that separate host utility. A complete bootable
Windows disk and valid firmware/NVRAM are still your responsibility.

The optional `optimize_windows_lite.py` now preserves Defender, SmartScreen,
Windows Update, code integrity and CPU mitigations. It refuses to overwrite an
existing cleanup image. It no longer invokes the legacy `opt_hive_arm64.exe`,
which disables protections. Do not use that legacy helper for this workflow.
No performance or idle-RAM improvement has been measured for the new profile.

## Install, import, then enable JIT

1. Pair your iPad with Xcode, trust the Mac and enable Developer Mode as required
   by the device. Register it in your development provisioning profile.
2. Build/sign, then explicitly install the app:

   ```bash
   ./scripts/install_on_device.sh DEVICE_ID distribution/WindowsiOS.app
   ```

3. Open WindowsiOS on the iPad. Create a machine in the VM Library and import
   firmware, variable store and prepared disk using the native file picker.
   Imports copy files into a private staging path, reject overwrites and publish
   after copying. Alternatively, use Finder file sharing to place files in
   `Documents/Machines/Win11/`; that directory is discovered by the library.
4. Set the desired per-machine options before starting. Choose 4 GiB initially;
   4.25/4.5 GiB depend on both host admission and the JIT-time RAM reservation.
5. To initialize the existing debugger-assisted JIT path, explicitly run:

   ```bash
   ./scripts/launch_on_device.sh DEVICE_ID me.ammaar.windowsios
   ```

6. The helper launches the app stopped and attaches to the **iPad process**.
   Select the machine and tap **Start Windows** on the iPad while the helper is
   active. iPad JIT allocation waits until this selection, so the reservation
   uses that machine's memory setting. The helper services known JIT traps and
   detaches; unknown stops are left stopped and reported as errors.
7. Wait for archive extraction if necessary, then for the guest firmware/Windows
   startup. Check JIT, USB and NAT backend status in session diagnostics.

These install and launch commands are procedures for the device owner; they
were not executed during this build-only session. `launch_on_duo.sh` remains
available for the original Duo workflow. With SDKs declaring the original
`UIHingeInteraction` API, enable `WINIOS_HINGE_SDK` in Swift compilation
conditions; the installed SDK does not declare that API, so its observer is
guarded and the original manual posture controls remain available.

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
  writes. This is a storage protection option, not a disposable snapshot.
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
| JIT trap/allocation failure | Record the OS/model and helper error. This device/OS combination remains unsupported until verified. |
| Insufficient reservation | Relaunch, select supported memory before Start, and initialize JIT again. No sub-4-GiB fallback is used. |
| Media missing | Import all three required files into the same machine. |
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
