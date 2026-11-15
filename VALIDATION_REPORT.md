# WindowsiOS verification report

Date: **2026-11-15**, America/Toronto. Target: **Windows 11 24H2 ARM64**,
confirmed by the user. Branch: `codex/ipad-24h2-build`.
Implementation commit: `69b2e7e`.

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
| Universal Swift/Objective-C/native application | **COMPILED** | `build/logs/ios-app-build-signed-final.log` ends with `BUILD SUCCEEDED`. |
| iPad device-target compilation | **COMPILED** | Generic `iphoneos` arm64 build; bundled `UIDeviceFamily` includes 2. No device run. |
| Duo/iPhone device-target compilation | **COMPILED** | Same universal arm64 artifact includes family 1; manual posture layout retained. Future hinge API excluded by SDK guard. No Duo run. |
| iOS dependencies | **COMPILED** | libffi 3.5.0, GLib 2.83.0, libslirp 4.9.1 and linked dependency archives staged in `ios/deps/`. |
| Signed app/IPA | **BUILT, SIGNATURE CHECKED** | `distribution/WindowsiOS.app`, `distribution/WindowsiOS-development.ipa`; `codesign --verify --strict` succeeded; IPA has `Payload/WindowsiOS.app`. |
| Build metadata | **RECORDED** | `distribution/BUILD_INFO.json`: arm64, iOS minimum 17.0, SDK 26.5, Xcode 26.6 (17F113), families [1,2]. |
| Baseline core regressions | **PASSED BEFORE SCOPE CHANGE** | `build/logs/core-baseline.log`: classifier 43 cases, operands 36 cases, JIT 10 programs × 2 seeds, memory 12 programs × 3 modes + MMIO, MMU 76 checks, exceptions 53 checks; all reported zero failures. JIT-region baseline also completed. No rerun after source changes. |
| New input/UI/config/lifecycle/storage tests | **NOT RUN — USER REQUEST** | Source and build checks only; no runtime assertions claimed. |
| Simulator UI checks | **NOT RUN — USER REQUEST** | Simulator compilation/execution is not native JIT verification. |
| Physical installation | **NOT TESTED** | No suitable connected iPad/Duo; install script supplied but unexecuted. |
| Device JIT initialization | **NOT TESTED** | Existing TXM trap protocol retained, selected-memory reservation added; no debugger attachment performed. |
| UEFI/Windows boot | **NOT TESTED** | No Windows disk/firmware was supplied locally, and VM execution was prohibited. |
| Keyboard/mouse/trackpad/Pencil | **NOT TESTED** | Native event → bridge → existing xHCI HID source path compiles; no physical or guest validation. |
| Guest network/audio/storage | **NOT TESTED** | Native backends and configuration compile; actual guest drivers, persistence and device behavior unverified. |
| Performance/thermal/Jetsam behavior | **NOT MEASURED — USER REQUEST** | No performance improvement, safe model matrix or boot-time result is claimed. |

Final signing used an existing local Apple Development identity and an eligible
Xcode-managed wildcard profile through automatic signing. The profile permits
**2 registered devices** and expires **2027-08-18 03:39:04 UTC**. Its
`get-task-allow` entitlement supports debugger attachment in principle, not proof
of JIT execution. An unregistered iPad requires a new eligible profile/rebuild.
No credentials or provisioning files were added to Git.

IPA SHA-256:

```text
c83b5f2f7aa5253429fa7a6fc0d47419cc79cecf08c50e7500e4094af5a88ed0
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

Implemented the native iPad library/session, staged non-overwriting media
imports, persistent validated configuration, hardware input, Pencil pointer
input and viewport zoom. Options map to existing engine facilities with explicit
additions for read-only primary disk, microphone capture gating, presentation
rate and one loopback TCP forward. The optional Windows cleanup no longer
invokes the legacy helper that disabled security services and mitigations.

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
