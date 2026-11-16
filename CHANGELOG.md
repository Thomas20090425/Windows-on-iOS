# Changelog

## 2026-11-15 — main source distribution and build entry point

- Made `main` the canonical branch for public downloads and continuation.
  The earlier `codex/ipad-24h2-build` name remains in historical milestones.
- Added root `Build.command` for double-click compilation from either a Git
  checkout or GitHub source ZIP. It checks full Xcode/Homebrew prerequisites,
  prepares missing build tools and invokes the existing app/dependency build
  with two workers by default. It honors development-signing configuration;
  the default build is unsigned and performs no app/device/VM execution.
- Removed unused dependency staging from optional ignored Husk checkouts;
  the app build uses the tracked recipe and declared source downloads.
- Added a prominent main source ZIP link and simplified download/build
  instructions. Clarified that tracked source/configuration recreate ignored
  generated Xcode projects, dependency payloads and app/IPA outputs.
- Updated the installation guide and agent continuation prompt for `main`.
  The latest existing Release artifact remains the build evidence below;
  adding the bootstrap does not establish a new clean-checkout build result.

## 2026-11-15 — universal iPad / Windows 11 24H2 ARM64 work

Branch: [`codex/ipad-24h2-build`](https://github.com/Thomas20090425/Windows-on-iOS/tree/codex/ipad-24h2-build).
This entry covers the branch changes from the inherited upstream baseline
through implementation revision [`661b8ae`](https://github.com/Thomas20090425/Windows-on-iOS/commit/661b8ae),
plus the accompanying documentation/handoff update. Detailed chronology is in
[PROGRESS_LOG.md](PROGRESS_LOG.md); continuation context is in
[AGENT_HANDOFF.md](AGENT_HANDOFF.md).

### App, configuration and input

- Added a native iPad VM library, persistent settings, staged imports and
  resizable Metal sessions while retaining the original Duo interface.
- Added engine-backed, UTM-informed settings for system, storage, network,
  audio, display and input. UTM was a configuration reference; its runtime was
  not substituted or copied into this engine.
- Added keyboard/mouse/trackpad input, horizontal scrolling, focus cleanup,
  Pencil contact/hover, and host zoom/pan. Corrected left/right/middle-button
  edges and preserved external button holds across hover/scroll/tap handling.
- Added real guest F1–F12 keys. With a physical keyboard connected, the app
  hides the full software keyboard and leaves the function-key row.
- Replaced fixed RAM presets with any whole-MiB entry from 4096 to the device
  limit, subject to 3072 MiB host headroom and the board map. Reservations must
  match the selected amount; the app does not silently shrink guest RAM.
- Added device capability admission and guarded process-global engine lifetime.
  Another session or a changed existing reservation requires app relaunch.
- Added confirmed deletion of old VMs, protecting running/engine-owned disks
  and preventing starts from racing deletion. Original ISO source files,
  bundled resources and other machines are preserved.

### Installation, firmware and TPM

- Replaced manual firmware/disk provisioning with Windows ARM64 ISO-only
  creation: bundled matched EDK2, private writable variables, a 64–512 GiB
  sparse Windows disk, USB optical media, and private driver/answer media.
- Restricted unattended partitioning answers to a marked fresh app-created
  blank disk, with capacity/content checks and removal after partitioning or
  warm reset. Existing disks do not receive automatic formatting answers.
- Added pinned firmware hashes, license/provenance resources and reproducible
  preparation scripts. User Windows media/licensing remain external.
- Added a real libtpms software TPM 2.0, firmware TIS/FIFO and Windows CRB/ACPI
  discovery, persistent per-VM identity/NV state, exclusive ownership, atomic
  writes and fail-closed loading/error handling. Warm reset retains keys.
- Pinned/cross-compiled libtpms 0.10.2 and OpenSSL 3.5.9; added fail-closed
  entropy handling, complete notices and the GPL version 3 linking explanation.
- Kept optional Windows cleanup from replacing existing output, preserved
  security/update/mitigation defaults, and stopped invoking the inherited
  security-disabling hive helper.

### Networking, CPU and graphics

- Bundled official ARM64 NetKVM/viogpudo drivers and resolution helpers from
  virtio-win 0.1.302-1, with pinned hashes, licenses and a 64 MiB read-only
  WINIOSDRVS USB medium. Fresh setup stages drivers; existing VMs have a logged
  InstallDrivers.cmd administrator workflow without OS reinstallation.
- Improved libslirp NAT startup/allocation/error handling and NetKVM MSI-X
  queue routing with an INTx fallback. Added the iOS local-network description.
- Unified the virtual CPU identity as Arm Cortex-A76 r4p1 across MIDR, device
  tree, SMBIOS and app labels; removed false host-chip/system branding.
- Added a real VirtIO GPU 2D device with resources, backing transfers, scanout,
  cursor, EDID, MSI-X and mode-change events. Preserved firmware RAMFB boot;
  added framebuffer lifetime locking and dirty-generation tracking.
- Added native-screen, window-fit and preset resolutions plus dynamic preferred
  mode requests handled by the official Windows service. Base EDID limits
  preferred dimensions to 4095 per axis; Windows controls the active mode.

### JIT and build tooling

- Gated custom BRK traps on an explicit helper-readiness handshake instead of
  assuming an ordinary Xcode attachment was compatible. Added setup feedback,
  exact trap validation and preservation of unrelated debugger stops.
- Resolved local app symbols using UUID-matched Mach-O metadata, per-image ASLR
  and Debug-dylib handling. Disabled external/background symbol lookup for the
  helper session and added visible preparation progress.
- Recorded the user's slow serial preparation results: bulk projected about
  22.2 minutes; serial one-byte/page writes projected about 31.6 minutes.
  Smaller payload alone did not solve debugger round-trip latency.
- Replaced the Mac default with an owned USB/loopback RSP proxy, pinned
  pymobiledevice3 11.55.1, and batches of up to 128 acknowledged page writes.
  All 24,576 pages of the 384 MiB region are still prepared and checked.
- Corrected the synchronous LLDB connect stall with asynchronous connection,
  a bounded connected-state wait, exact-PID stopped attachment and a startup
  watchdog. Current completion time and full JIT success remain unverified.
- Added two-worker compile/sign/package scripts, install/launch helpers,
  firmware/driver preparation and artifact manifests. Generated products and
  signing/VM/Windows media stay outside Git.

### Documentation and verification

- Added installation, validation, progress, firmware/TPM provenance, UTM
  configuration mapping, and Windows driver/display guides.
- Rewrote the README around the current build/setup and bounded feature status;
  preserved the inherited upstream showcase as clearly labeled history.
- Added this changelog and a standalone agent handoff with source map,
  constraints, known gaps, artifact evidence and a continuation prompt.
- Latest integrated signed **Release** build: Xcode 26.6 / iOS SDK 26.5,
  arm64 device families 1 and 2, two workers; signature/package checks passed.
  Log: `build/logs/ios-app-build-network-display-signed.log`.
  IPA SHA-256:
  `5251bfa1a41465efcb1e7898412bdabd8effc79bc1097aaceb2c918bd9214d70`.
- Earlier Debug and pre-constraint baseline evidence are historical only. No
  tests, simulator, debugger, app, VM or benchmarks were run after the owner's
  build-only instruction. This documentation update requires no app rebuild.

### Known limits

Windows installation/boot, TPM enrollment/persistence, current JIT completion,
physical input, driver trust, Internet access and dynamic modes remain
runtime-unverified. No speedup, universal iPad compatibility or Windows platform
compliance is claimed. Accelerated 3D/GPU passthrough, full Pencil digitizer/Ink,
complete VM teardown, suspend and snapshots remain unavailable.

### Commit index

| Commit | Milestone |
| --- | --- |
| [69b2e7e](https://github.com/Thomas20090425/Windows-on-iOS/commit/69b2e7e) | Native iPad sessions, Pencil and validated VM configuration. |
| [bf04d36](https://github.com/Thomas20090425/Windows-on-iOS/commit/bf04d36) | Installation guide and compile-only evidence. |
| [01b9340](https://github.com/Thomas20090425/Windows-on-iOS/commit/01b9340) | ISO-only setup, bundled UEFI and in-app disk creation. |
| [56d7372](https://github.com/Thomas20090425/Windows-on-iOS/commit/56d7372) | ISO setup and artifact documentation. |
| [99dbef2](https://github.com/Thomas20090425/Windows-on-iOS/commit/99dbef2) | Helper-readiness gating and safe VM deletion. |
| [99ec20a](https://github.com/Thomas20090425/Windows-on-iOS/commit/99ec20a) | Startup recovery/deletion documentation. |
| [6c5a5e7](https://github.com/Thomas20090425/Windows-on-iOS/commit/6c5a5e7) | UUID-matched local symbols for device JIT. |
| [226a42e](https://github.com/Thomas20090425/Windows-on-iOS/commit/226a42e) | Local symbol discovery and preparation progress. |
| [7007144](https://github.com/Thomas20090425/Windows-on-iOS/commit/7007144) | Sparse serial page writes, subsequently superseded as the default. |
| [e19d30b](https://github.com/Thomas20090425/Windows-on-iOS/commit/e19d30b) | Observed serial latency and optional StikDebug documentation. |
| [9182936](https://github.com/Thomas20090425/Windows-on-iOS/commit/9182936) | Batched Mac JIT over an owned USB transport. |
| [f82c1aa](https://github.com/Thomas20090425/Windows-on-iOS/commit/f82c1aa) | Asynchronous connect to avoid the pre-attach LLDB stall. |
| [bde8116](https://github.com/Thomas20090425/Windows-on-iOS/commit/bde8116) | Persistent software TPM2, numeric RAM and hardware input/F keys. |
| [661b8ae](https://github.com/Thomas20090425/Windows-on-iOS/commit/661b8ae) | ARM64 driver media, CPU/network fixes, VirtIO display and resolutions. |
