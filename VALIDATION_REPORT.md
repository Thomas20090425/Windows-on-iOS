# WindowsiOS verification report

Date: **2026-11-15**, America/Toronto. Target: **Windows 11 24H2 ARM64**,
confirmed by the user. Branch: `codex/ipad-24h2-build`.
Initial universal-app implementation commit: `69b2e7e`. This report now covers
the ISO-only setup correction `01b9340` and rebuilt artifacts.

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
| Universal Swift/Objective-C/native application | **COMPILED** | `build/logs/ios-app-build-iso-signed.log` ends with `BUILD SUCCEEDED`; includes ISO wizard, disk creation, FAT16 answer generator and USB optical transport. |
| iPad device-target compilation | **COMPILED** | Generic `iphoneos` arm64 build; bundled `UIDeviceFamily` includes 2. No device run. |
| Duo/iPhone device-target compilation | **COMPILED** | Same universal arm64 artifact includes family 1; manual posture layout retained. Future hinge API excluded by SDK guard. No Duo run. |
| iOS dependencies | **COMPILED** | libffi 3.5.0, GLib 2.83.0, libslirp 4.9.1 and linked dependency archives staged in `ios/deps/`. |
| Signed app/IPA | **BUILT, SIGNATURE CHECKED** | `distribution/WindowsiOS.app`, `distribution/WindowsiOS-development.ipa`; `codesign --verify --strict` succeeded; IPA has `Payload/WindowsiOS.app`. |
| Build metadata | **RECORDED** | `distribution/BUILD_INFO.json`: arm64, iOS minimum 17.0, SDK 26.5, Xcode 26.6 (17F113), families [1,2]. |
| Bundled UEFI/variable template | **PACKAGED, HASHES CHECKED** | Matched 64 MiB `Firmware/code.fd` and `vars-template.fd` included in signed app. Pinned Debian EDK2 2025.02-8+deb13u1 package; manifest records hashes. Full licenses/provenance included. This proves packaged bytes, not firmware execution. |
| Baseline core regressions | **PASSED BEFORE SCOPE CHANGE** | `build/logs/core-baseline.log`: classifier 43 cases, operands 36 cases, JIT 10 programs × 2 seeds, memory 12 programs × 3 modes + MMIO, MMU 76 checks, exceptions 53 checks; all reported zero failures. JIT-region baseline also completed. No rerun after source changes. |
| New input/UI/config/lifecycle/storage tests | **NOT RUN — USER REQUEST** | Source and build checks only; no runtime assertions claimed. |
| Simulator UI checks | **NOT RUN — USER REQUEST** | Simulator compilation/execution is not native JIT verification. |
| Physical installation | **NOT TESTED** | No suitable connected iPad/Duo; install script supplied but unexecuted. |
| Device JIT initialization | **NOT TESTED** | Existing TXM trap protocol retained, selected-memory reservation added; no debugger attachment performed. |
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
75d99ae16d53456d616f73706743dc911fa64dc096283a4032cc116087465dde
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
