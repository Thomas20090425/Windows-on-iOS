# Engineering progress — 2026-11-15

Target clarified by user: Windows 11 **24H2** ARM64 (not “24H4”).
User subsequently requested **compilation only**, with no tests, VM execution,
profiling or debugger use on this Mac. Later additions: Apple Pencil input and
UTM-informed, engine-backed VM configuration.
The user then corrected setup requirements: **Windows ISO only**, firmware
bundled with the app, automatic private NVRAM, and app-created writable disks.
The user subsequently reported a start-time `EXC_BREAKPOINT` in the JIT
assembly and requested deletion of past VMs.
Their subsequent Mac launcher log reached device attachment but failed to find
the readiness symbol; remote symbol availability had been mistaken for app age.

## Completed source work

- iPad VM Library, persistent machine configuration, staged imports, native
  settings and a resizable Metal session over the existing execution engine.
- Native external keyboard/mouse/trackpad path, horizontal USB wheel, focus and
  held-input cleanup, Pencil pointer/hover, host pinch zoom/pan.
- Runtime capability admission, selected RAM reservation before iPad JIT,
  conservative host headroom and explicit rejection of unsupported phones.
- Disk extraction keeps existing writable images and source archives; unsafe
  process-global engine recreation is blocked until app relaunch.
- UTM-referenced system/storage/network/audio/display/input configuration;
  no QEMU/UTM runtime substitution or copied UTM source.
- Dependency builds, generic arm64 app compilation, install/launch scripts,
  original Duo path and SDK-safe conditional hinge observer.
- Optional Windows cleanup preserves security/update/mitigation defaults and
  rejects replacement of an existing cleanup image.
- Replaced normal media import with an ISO-only creation wizard and 64–512 GiB
  sparse disks in iPad app storage. Added fresh per-VM variables, genuine USB
  optical media, and a generated FAT16 unattended setup disk guarded to fresh
  app-created blank targets. Warm resets remove formatting answers after disk
  partitioning, preserving existing installations.
- Bundled matched EDK2 code/variable-template banks with pinned Debian package
  checksums, provenance and redistribution notices. No user firmware import.
- Replaced the assumption that Xcode's debug attachment implies JIT support
  with an explicit helper readiness handshake. Matching LLDB/StikDebug scripts
  arm it before resuming, validate protocol responses and preserve unknown
  stops. Ordinary Xcode Run now returns JIT setup status before emitting BRK.
- Added iPad Enable JIT actions, visible helper-open errors and VM deletion
  with confirmation, native ownership checks, strict directory validation and
  a deletion reservation preventing new starts from racing removal.
- Corrected launcher symbol resolution: local `.app` metadata includes Xcode's
  Debug dylib, device image UUIDs must match, ASLR relocation is per image, and
  deferred Debug loading stops at bootstrap before JIT readiness is written.
  Missing metadata, unloaded images and mismatched builds now have distinct
  diagnostics. Universal and Duo launchers share the metadata preflight.

## Build evidence and constraints

- Baseline native archive and generic arm64 iOS app compiled successfully after
  installing missing build prerequisites and guarding an unavailable hinge API.
- Core baseline checks had completed before the user added the build-only
  constraint. No subsequent tests or runtime checks were performed.
- Final integrated **signed build succeeded**; app, development IPA and manifest
  are in `distribution/`. Final log: `build/logs/ios-app-build-jit-delete-signed.log`.
  Signature/package checks passed. Installation is limited to the embedded
  development profile's seven registered devices. Full evidence is in VALIDATION_REPORT.md.
- Implementation milestone: `69b2e7e` — native iPad sessions, Pencil input and
  validated VM configuration, on `codex/ipad-24h2-build`.
- ISO-only setup correction: `01b9340` — bundled UEFI, fresh NVRAM, app-created
  Windows disk, USB optical media and generated automatic setup answers.
- Startup/deletion correction: `99dbef2` — helper handshake and guarded VM
  deletion. Release and Debug arm64 configurations both compiled; helper syntax
  checks and signature/package checks passed. No runtime checks or deletion ran.
- Launcher symbol correction: Python/shell syntax compilation passed, and local
  Release/Debug symbol manifests were generated through read-only Mach-O
  inspection. No app source changed or new app build was needed; no debugger,
  device/VM execution or runtime test was performed for this correction.

## Remaining external/runtime work

- Install on an appropriately provisioned iPad; verify the JIT trap protocol,
  actual memory behavior, UEFI/Windows boot, physical input and guest I/O.
- No suitable iPad/Duo was available. No Windows media was supplied locally.
- ISO boot/unattended setup remains unverified. No virtual TPM is implemented;
  Windows Setup may reject the platform. No requirement bypass or fabricated
  successful installation was added.
- Pencil pressure/tilt/eraser/Windows Ink digitizer support, complete VM teardown,
  suspend/snapshots, dynamic guest resolution and accelerated guest graphics
  remain unavailable. No speedup or universal iPad compatibility is claimed.
