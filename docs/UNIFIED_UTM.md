# UTM ARM Lab

The requested target is one iPad app: UTM's actual library and configuration
interface, the existing Windows ARM64 engine, and Henge's macOS ARM64 engine.
The earlier separate-app Engines sheet is only a reference experiment and does
not satisfy this target.

## Source layout

- UTM frontend: pinned at `5d5e1b180be867c795bbeb03ed80087518c0cdae`, with
  `scripts/patches/utm-unified.patch` adding the `NativeARM64` configuration
  backend, native library entries, creation/settings and session routing.
- Windows engine: existing repository sources, compiled into
  `WindowsBackend.framework` by `scripts/build_windows_backend.sh`.
- macOS engine: Henge pinned at `7b557301195f130f900b1b4cd105c9ecf0fbc109`, with
  the complete upstream-relative `scripts/patches/henge-unified.patch`, compiled
  into `HengeBackend.framework` by `scripts/build_henge_backend.sh`.
- `scripts/prepare_unified_utm_project.py` generates a sibling Xcode project;
  it leaves UTM's original project untouched and embeds both frameworks.

Both engines share native symbol names inherited from related ARM64 engines.
Each framework exports only its frontend bridge and explicit debugger entry
points. Its internal engine, libslirp and GLib symbols remain local. Their
SwiftUI types also live in separate Swift modules.

## Machines and lifecycle

UTM continues to handle its normal QEMU machine configurations. New native
entries persist an explicit engine choice in `config.plist`; they do not pretend
to be QEMU or Apple's Virtualization.framework configurations. Native Windows
data lives in the bundle's `Data/`, and Henge data in `Data/Henge/`.

Windows setup accepts an ARM64 ISO and creates its disk, private NVRAM and TPM
state. A prepared-machine import copies the complete source folder. macOS setup
accepts an IPSW or Henge's Apple download/restore flow. Import preserves the
source folder; shut the source guest down before making a disk copy.

An app process claims one execution-engine family. Close and reopen the app to
change families or start another native machine. Native snapshot, recovery and
remote-session capabilities are not advertised. Henge's installer also requires
a fresh app process before the installed Mac's first boot. macOS account setup
remains the user's responsibility.

The original Windows app, standalone UTM and standalone Henge retain their own
containers. Building this app does not migrate or modify their guest disks.

## Build and launch

Prepare the pinned UTM native dependencies using
`scripts/build_utm_reference.sh` first. Then:

```sh
DEVELOPMENT_TEAM=V3C22X6SVS ./scripts/build_unified_app.sh
```

The build writes `distribution/unified/UTM.app`, `UTM-ARM-Lab.ipa` and a
provenance receipt. It preserves an existing output and accepts
`UNIFIED_OUTPUT_DIR` for another build. `JOBS=2` is the default.

After installing the exact app, shut down its guest before using either launch
command; the launcher deliberately relaunches the app:

```sh
./scripts/launch_unified_on_device.sh DEVICE_ID windows distribution/unified/UTM.app
./scripts/launch_unified_on_device.sh DEVICE_ID macos distribution/unified/UTM.app
```

Both launchers inspect the selected embedded framework's Mach-O UUID and exact
JIT trap instructions. Windows additionally verifies its writable readiness
word. No addresses from the standalone apps are reused for the unified build.

The existing standalone Henge build still uses:

```sh
./scripts/launch_henge_on_device.sh DEVICE_ID distribution/henge-macos/Henge.app
```

Henge uses ARM64-to-ARM64 JIT software emulation and Metal GPU command replay.
This integration does not add stock-iPad hypervisor access or GPU passthrough.
See [Henge's architecture](https://github.com/Leviidev/Henge/blob/main/docs/architecture.md).

## Validation status

The final iPhoneOS ARM64 app builds and signs successfully, including both
embedded backends and the input, renderer and lifecycle fixes. The IPA SHA-256
is `60779822a7c989bc1182576ffd26d4b071d4f49b7093b251e3cdb0f83bc0d026`.
Deep signature checks, profile-authorized memory capabilities, internal-symbol
isolation and both embedded-image JIT manifests pass.

Focused input checks cover fractional trackpad scrolling, conventional
mouse-wheel detents, finite motion bounds and preservation of large signed
pointer movement without signed-byte wrap. Physical trackpad events no longer
enter the emulated touchscreen finger path. UTM's native configuration tests
exercise imports, media replacement, RAM validation and preservation of disks,
NVRAM, TPM, auxiliary storage and Mac identity, including error paths.

The Metal fix replaces empty fallback textures with aligned shared backing,
created before returning a texture's resource ID. Matching guest aliases share
that backing; GPU uploads and packed-layout writeback are ordered before
completion stamps. The actual Metal harness passes on an Apple M3 with API
validation enabled for BGRA8 and RGBA16F layouts seen in the iPad log, odd-byte
rows, repeated CPU writes, queued GPU frames and 1920 × 1440 half-float output.

Reproduce the focused checks with:

```sh
python3 scripts/test_utm_native_configuration.py
./scripts/check_henge_linear_backing.sh
xcrun swiftc work/references/Henge/ios/Henge/PhysicalMouseButtons.swift \
  research/Unified/HengeInputValidation.swift -o build/henge-input-validation
./build/henge-input-validation
```

Evidence is in `build/logs/unified-utm-build.log`,
`build/logs/utm-native-model-check-root.log`,
`build/logs/utm-unified-project-check.log`,
`build/logs/utm-unified-static-jit-review.log` and
`build/henge-graphics/test-linear-backing.log`.

The unified app has not yet been installed or booted on the iPad. The existing
Henge guest was observed running the user's Geekbench workload with 8192 MiB
RAM, and has been preserved. Device verification of the graphics/input fixes,
their frame cost, both native boots and the complete install flow remains
pending. The signed artifact is ready for that next step.
