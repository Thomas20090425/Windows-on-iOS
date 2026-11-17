# Engineering progress — 2026-11-15

Latest delivery: one signed **UTM ARM Lab** app now embeds the existing Windows
ARM64 engine and Henge's macOS/IPSW engine behind UTM's actual frontend.
Native bundles/settings/imports and VM-specific session routes replace the
separate-app hub as the requested target. Built final IPA:
`distribution/unified/UTM-ARM-Lab.ipa`, SHA-256
`60779822a7c989bc1182576ffd26d4b071d4f49b7093b251e3cdb0f83bc0d026`.
Both framework export boundaries and exact-image JIT manifests pass. Added
fractional physical-trackpad scrolling, signed movement packetization,
direct-touch filtering, canonical aligned Metal texture backing with ordered
guest/GPU synchronization, and retained-session/restore shutdown handling.
Configuration/import/error-path checks, focused input checks and real Metal
tests pass. Device installation and guest validation are pending because the
current Henge Mac is actively running the user's Geekbench workload. See
[the unified integration record](docs/UNIFIED_UTM.md).

Target clarified by user: Windows 11 **24H2** ARM64 (not “24H4”).
User subsequently requested **compilation only**, with no tests, VM execution,
profiling or debugger use on this Mac. Later additions: Apple Pencil input and
UTM-informed, engine-backed VM configuration.
The subsequent UTM/macOS research request explicitly authorized dependency
builds, device installation, JIT and macOS guest restoration/execution. This
later authorization supersedes the earlier compile-only research boundary.
The user then corrected setup requirements: **Windows ISO only**, firmware
bundled with the app, automatic private NVRAM, and app-created writable disks.
The user subsequently reported a start-time `EXC_BREAKPOINT` in the JIT
assembly and requested deletion of past VMs.
Their subsequent Mac launcher log reached device attachment but failed to find
the readiness symbol; remote symbol availability had been mistaken for app age.
The next log passed readiness/probe/RX allocation and stopped reporting progress
while LLDB displayed external-symbol lookup during memory preparation.
Subsequent user progress (21 MiB in 72.9 s) showed that full-region preparation
was advancing slowly, projecting 22.2 minutes at that measured rate.

## Completed source work

- Cloned pinned UTM and Henge. Built and installed full UTM using its official
  QEMU/SPICE sysroot and a separate source-built Henge app. Added Windows
  settings navigation (nine categories), validated draft Save/Cancel,
  rename/notes/search and an Engines companion launcher. Pinned build recipes,
  patches, source manifests and license/provenance receipts are retained.
- On the M5 iPad, Henge JIT's generated-code check returned 42 and detached;
  Sequoia 15.6.1 downloaded from Apple, restored successfully, and booted a 6 GiB
  guest with Metal/PVG graphics to Setup Assistant. The user chose to complete
  account setup personally. Automatic guest commands were cleared. The active
  original Windows VM was not terminated or updated. Details/evidence:
  `docs/VIRTUALIZATION_RESEARCH.md`.
- Fixed a confirmed false RAM rejection: the connected original app's saved
  diagnostics showed JIT live, 0 MiB guest reservation and 4698 MiB process
  headroom, while the old gate demanded 5120 MiB for a 4096 MiB guest. Startup
  now reserves the actual exact-size mapping before engine creation, requiring
  only engine headroom for the file-backed path. The fallback uses a unique
  temporary file with all storage reserved, lazy shared mapping, explicit
  errors and no silent anonymous fallback. Failed replacements retain the
  prior mapping; sizes can be retried before engine creation. Added a build
  switch to omit optional capabilities for the original app ID/profile.
- Added Increased Memory Limit and Extended Virtual Addressing to the source
  signing recipe. The original bundle ID was unavailable to this Mac's team,
  so a separate Windows 11 RAM variant uses com.thomas20090425.windowsios and
  an explicit profile granting both entitlements. Original distribution
  artifacts and the installed app remain untouched. The 16 GiB device's
  physical admission policy already allows 13 GiB; the roughly 5 GiB symptom
  instead needs process-budget/reservation evidence. Added separate memory
  diagnostics and exact admission errors, stopped eager full-file prefault on
  iOS and made RAM-metadata allocation failure stop startup.
- Made the F1–F12 row default-hidden behind a floating F keys button. It opens
  over the guest viewport and has a hide arrow; it no longer occupies a bottom
  inset or resizes Windows. Typing keyboard is separate, and the iPad viewport
  fills the screen even while the software keyboard is open.
- Added a guest display-selection helper to the bundled driver disk. It
  identifies the connected VirtIO PCI adapter, validates a single-display
  topology and saves it with the firmware desktop disconnected. The installer
  applies it interactively and registers it for sign-in; existing VMs need the
  updated installer once. Boot RAMFB and both signed driver packages remain.
- Added official pinned ARM64 NetKVM/display packages and resolution helpers
  as bundled read-only USB LUN2 media. Fresh setup stages drivers and attempts
  permanent helper installation; existing VMs can run the included logged
  installer once. Improved NAT startup/allocation failure handling and added
  queue-specific MSI-X with INTx fallback for the network adapter.
- Corrected guest CPU branding to Arm Cortex-A76 r4p1 (virtual), shared across
  MIDR, FDT, SMBIOS and the app. Removed false host-chip/system names.
- Added real VirtIO GPU 2D resources, cursor, scanout, EDID and mode-change
  events, plus native/window/preset resolution controls. The official guest
  service handles runtime modesets. Retained firmware RAMFB boot and added
  framebuffer locking/update generations for dynamic scanout lifetime safety.
- iPad VM Library, persistent machine configuration, staged imports, native
  settings and a resizable Metal session over the existing execution engine.
- Native external keyboard/mouse/trackpad path, horizontal USB wheel, focus and
  held-input cleanup, Pencil pointer/hover, host pinch zoom/pan.
- Runtime capability admission, selected RAM reservation before iPad JIT,
  conservative host headroom and explicit rejection of unsupported phones.
- Added libtpms-backed software TPM 2.0 with a genuine firmware FIFO frontend,
  Windows ACPI CRB frontend, per-VM persistent identity/NV state and fail-closed
  state loading. OpenSSL/libtpms are pinned, cross-compiled and bundled with
  notices; no external TPM driver or user firmware import is needed.
- Replaced the RAM presets with whole-MiB numeric entry, removing the 4.5 GiB
  cap and 256 MiB step. Native/JIT reservation uses the exact requested amount
  within physical memory minus 3 GiB host headroom and the board memory map.
- Added actual F1–F12 buttons and physical-keyboard detection. A connected
  keyboard hides the full onscreen keyboard; the F row is now an optional overlay.
  Mouse state now includes direct GCMouse button edges and passive UIKit
  mouse/trackpad observation before UIView gesture cancellation, preserving
  external holds across hover, wheel and delayed synthetic-tap releases.
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
- Limited this helper's LLDB symbol discovery to local metadata, including
  explicit UUID-matched dSYM files when present. Added memory preparation
  progress in both transfer paths. No persistent debugger setting was changed.
- Changed default JIT preparation to one acknowledged raw debugger byte per
  16 KiB page, using the upstream page coverage protocol. All 24,576 pages in
  the 384 MiB region are still visited; the payload is 24 KiB rather than
  384 MiB. Preserved RX checks and added an observed ETA. A packet-size-tuned
  bulk mode remains explicit diagnostics only; no measured new speedup claimed.
- Replaced that serial default after the user's timing showed it was slower.
  Mac launches now use an owned loopback RSP proxy and pinned pymobiledevice3
  USB forwarder, sending up to 128 page commands before collecting their exact
  acknowledgements. The entire 384 MiB allocation is still prepared. Compression
  refusal, no-ack negotiation/checksum handling, target-stop checks and fatal
  unexpected traffic prevent protocol drift. Existing UUID/readiness/RX checks
  remain. The original Xcode transport is explicit fallback with bounded
  bulk/page calibration. StikDebug installation is not required for the Mac path.

## Build evidence and constraints

- Baseline native archive and generic arm64 iOS app compiled successfully after
  installing missing build prerequisites and guarding an unavailable hinge API.
- Core baseline checks had completed before the user added the build-only
  constraint. No subsequent tests or runtime checks were performed.
- Earlier startup/deletion **signed build succeeded**; its app, development IPA
  and manifest in `distribution/` were superseded by the later milestones below.
  Milestone log: `build/logs/ios-app-build-jit-delete-signed.log`.
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
- User-provided evidence now confirms readiness read-back, probe handling and
  384 MiB RX allocation. Completed JIT preparation/execution remains unverified.
  The follow-up symbol-search/progress adjustment passed syntax compilation and
  local dSYM metadata preparation only; no LLDB/device/VM was run by the agent.
- The sparse transport change passed Python syntax compilation and static
  protocol review. The baseline timing came from the user's device log; the
  new preparation path still needs a device timing/functional result.
- Subsequent user timing disproved a speed improvement for the serial sparse
  Mac path on this connection: 316 pages/24.4 s projected over 30 minutes.
  Investigated StikDebug's 128-command batching and verified the app's existing
  custom-script URL handoff against official source. Recommended evaluating
  that path; no completion-time or Windows-boot claim and no agent runtime run.
- The user then selected computer-only launching. Implemented the batched Mac
  transport, installed its dependencies in `work/mac-jit-venv`, and completed
  Python/shell syntax compilation and independent source review. No debugger,
  device tunnel, VM, or test workload was run. No native app source changed;
  the existing signed app remains applicable. New batch timing remains unverified.
- Follow-up user output reached batch-proxy no-ack negotiation but stalled in
  synchronous `process connect` before attachment. Corrected that LLDB deadlock
  with asynchronous connection, a bounded connected-state wait, synchronous
  exact-PID attach, stopped-state verification and a 60 s startup watchdog.
  Python/shell syntax compilation and independent source review passed. No app
  rebuild, debugger/device execution or runtime tests were performed.
- Software TPM/input milestone **signed Release build succeeded** with two build
  workers. It produced the app/IPA and updated manifest in `distribution/`; log:
  `build/logs/ios-app-build-tpm-input-signed.log`. Real TPM symbols and bundled
  notices/provenance were inspected, and the local launch-symbol manifest was
  regenerated from the new Mach-O. No tests, debugger, simulator, device tunnel
  or VM execution. Device TPM enrollment/input/RAM behavior remain unverified.
- Networking/display/CPU **signed Release build succeeded** with two workers.
  Latest app/IPA/manifest are in `distribution/`; log:
  `build/logs/ios-app-build-network-display-signed.log`. Bundled driver image
  hash matches its manifest, actual GPU/media symbols are linked and local
  launch metadata was regenerated. No driver, simulator, debugger, device or
  VM execution; Internet access, guest driver trust and mode switching remain
  runtime-unverified.

- The display/keyboard correction built successfully in signed Release with
  Xcode 27.2 / iOS SDK 27.2 and two workers. Log:
  `build/logs/display-keyboard-overlay-build.log`. App signature, IPA integrity,
  helper hashes in bundled provenance and driver-disk hashes were checked;
  local JIT symbol metadata was regenerated. No Windows, simulator, device,
  debugger or tests ran. Guest topology selection and keyboard interaction
  remain unverified on the user's device.

- The memory-enabled variant built and signed with Xcode 27.2 / iOS SDK 27.2,
  two workers; log: `build/logs/memory-enabled-build.log`. Both memory grants
  were verified in the app signature and explicit embedded profile; signature,
  IPA integrity, local symbol metadata and original-artifact preservation
  checks passed. Outputs are in `distribution/memory-enabled/`. Different app
  identity requires owner-run VM folder copying before reuse. No iPad install,
  RAM allocation, debugger, VM, simulator or tests ran for this change.

## Remaining external/runtime work

- Corrected reservation builds passed in signed Release for both original and
  memory-capability IDs. Logs: `build/logs/reservation-fixed-original-build.log`
  and `build/logs/reservation-fixed-memory-build.log`. App signatures, embedded
  capability grants/omissions, IPA integrity and local JIT metadata were checked.
  Original-ID fix is in `distribution/reservation-fixed-original/`; entitled
  fix is in `distribution/memory-enabled/`. Device work was read-only app listing
  and copying existing boot_status.txt; no app/VM launch or allocation ran.
- Install on an appropriately provisioned iPad; verify the JIT trap protocol,
  actual memory behavior, UEFI/Windows boot, physical input and guest I/O.
- No agent-run iPad/Duo runtime validation was performed under the build-only
  constraint. No Windows media was supplied locally.
- ISO boot/unattended setup and the new software TPM's firmware/Windows handoff
  remain unverified. Windows Setup may reject other platform requirements.
  No requirement bypass or fabricated successful installation was added.
- Pencil pressure/tilt/eraser/Windows Ink digitizer support, complete VM teardown,
  suspend/snapshots and accelerated 3D guest graphics
  remain unavailable. No speedup or universal iPad compatibility is claimed.
