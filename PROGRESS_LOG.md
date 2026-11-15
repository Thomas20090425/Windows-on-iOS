# Engineering progress — 2026-11-15

Target clarified by user: Windows 11 **24H2** ARM64 (not “24H4”).
User subsequently requested **compilation only**, with no tests, VM execution,
profiling or debugger use on this Mac. Later additions: Apple Pencil input and
UTM-informed, engine-backed VM configuration.

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

## Build evidence and constraints

- Baseline native archive and generic arm64 iOS app compiled successfully after
  installing missing build prerequisites and guarding an unavailable hinge API.
- Core baseline checks had completed before the user added the build-only
  constraint. No subsequent tests or runtime checks were performed.
- Final integrated **signed build succeeded**; app, development IPA and manifest
  are in `distribution/`. Final log: `build/logs/ios-app-build-signed-final.log`.
  Signature/package checks passed. Installation is limited to the embedded
  development profile's two registered devices. Full evidence is in VALIDATION_REPORT.md.
- Implementation milestone: `69b2e7e` — native iPad sessions, Pencil input and
  validated VM configuration, on `codex/ipad-24h2-build`.

## Remaining external/runtime work

- Install on an appropriately provisioned iPad; verify the JIT trap protocol,
  actual memory behavior, UEFI/Windows boot, physical input and guest I/O.
- No suitable iPad/Duo was available. No Windows media was supplied locally.
- Pencil pressure/tilt/eraser/Windows Ink digitizer support, complete VM teardown,
  suspend/snapshots, dynamic guest resolution and accelerated guest graphics
  remain unavailable. No speedup or universal iPad compatibility is claimed.
