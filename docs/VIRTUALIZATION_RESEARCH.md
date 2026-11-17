# UTM and macOS on the M5 iPad

The user subsequently clarified that the deliverable must be one app using
UTM's actual frontend with embedded Windows and Henge engines. That integration
is described in [UTM ARM Lab](UNIFIED_UTM.md). The separate-app results below
remain useful baseline evidence; the Engines hub is not the requested final
architecture.

Recorded 2026-11-15, America/Toronto. The user explicitly authorized cloning
UTM, building dependencies, installing research apps, downloading an Apple
restore image, and running a macOS guest on the iPad. That authorization lifts
the earlier build-only restriction for this research work. Restores target
new guest disk files; the physical iPad firmware is unchanged.

## Current result

| Component | Result | Boundary |
| --- | --- | --- |
| WindowsiOS controls | Nine settings pages, draft Save/Cancel, rename, notes, search and Engines hub; signed build passed | Updated original-ID app is staged. Its existing Windows VM reported running, so the installed copy was not replaced. |
| Full UTM | Current source cloned, built and installed with official QEMU/SPICE sysroot | Separate companion app. Its guest engines and individual functions have not been runtime-tested here. |
| Henge macOS | Built, signed, installed; JIT generated-code execution passed; Apple restore completed; macOS booted to Setup Assistant | Separate companion app using software emulation and Metal replay. User requested to complete account setup personally. |

The Engines sheet opens the independently installed UTM and Henge libraries.
WindowsiOS does not embed QEMU, import arbitrary `.utm` configurations, or share
VM containers with those apps. Full `.utm` handling belongs to the installed
UTM build. Apple's native macOS Virtualization framework backend requires a
Mac host; Henge supplies the iPad route.

The Windows settings pages cover Information, System, Drives, Display, Input,
Network, Sharing, Audio and Diagnostics. Existing functional options remain
connected to the same native execution paths. Save validates the current RAM
and port text before persisting; Cancel leaves the saved configuration intact.
No unsupported hardware selectors or snapshot controls were added to this
engine. UTM's own app provides its corresponding complete frontend/backend.

## On-device evidence

- Connected device: iPad Pro 13-inch (M5), `iPad17,4`, iPadOS 26.3.1 (a).
- Henge identity: `com.thomas20090425.henge`, with a separately provisioned
  `.JITHelper`. Increased Memory Limit and Extended Virtual Addressing are
  authorized in both app signature and provisioning profile. Unsupported
  `dynamic-codesigning` was omitted from this development build.
- The Mac launcher verified loaded/local Mach-O UUIDs and exact BRK opcodes,
  prepared a 512 MiB RX/RW JIT mapping, and detached. The iPad log reports the
  generated-code self-test returning 42.
- Apple's Sequoia restore image downloaded on the iPad: **16,814,137,790 bytes**,
  `UniversalMac_15.6.1_24G90_Restore.ipsw`. Its URL is in the pinned upstream
  installer source. The CDN publishes SHA-256
  `3d87686b691ac765eb6a6b3082b2334e2af9710096a00432dd519af89ff2ea78`;
  a separate whole-archive SHA-256 calculation was not performed on the device.
- The virtual boot ROM was fetched from Apple's Sonoma image and verified by
  Henge against its pinned ROM SHA-256. It is not bundled in the app or Git.
- Restore log: `Status: Restore Finished`, `restore finished: 0`, step 100.
  The virtual disk was flushed before the initial boot.
- New guest **ResearchMac**: 4 virtual CPUs, **6144 MiB guest RAM**, 512 MiB JIT,
  1920 × 1440 guest display. Logs confirm the requested 6144 MiB mapping.
- The guest reached the animated welcome screen and the language-selection
  stage of Setup Assistant. PVG/Metal logs show submitted surfaces and draw
  commands; the guest image was captured directly from its display.
- No macOS account was created, in accordance with the user's explicit choice.
  The automatic command queue was replaced with a comment, preventing setup
  actions from replaying on the next development launch.

Evidence remains local under `build/henge/` and `build/logs/`:
`henge-restore.log`, `henge-first-boot.log`, `setup-assistant.jpg`, `language.jpg`,
`henge-device-jit-launch.log`, `henge-first-boot-launch.log`, and install JSON
receipts. These are ignored build outputs, not committed evidence artifacts.

Henge is **JIT software emulation**, not EL2 hardware virtualization. The M5
executes translated CPU code; the engine handles privileged behavior, MMU and
devices. Guest PVG graphics commands are replayed through Metal, not direct
GPU passthrough. This successful boot does not establish compatibility with
every macOS GPU workload. An unsupported small texture-layout warning appears
in the log; applications such as Safari have not been checked in this guest.
No general performance or near-native-speed claim is made.

## Sources, artifacts and rebuilds

| Project | Pinned source | Build record |
| --- | --- | --- |
| UTM | `5d5e1b180be867c795bbeb03ed80087518c0cdae` | `research/utm-source.json`, `scripts/build_utm_reference.sh` |
| Henge | `7b557301195f130f900b1b4cd105c9ecf0fbc109` | `research/henge-source.json`, `scripts/build_henge_reference.sh` |
| Husk pairing dependency | `afe83d45b31194c4cc9f7b3db7ec2c757db8346e` | Henge source manifest and dependency receipt |
| StikJIT 1.9.0 | `32287268fa5824f9edce4cb359f5833ce0cf7b00` | Henge's full-width-address patch retained |

UTM used its official `Sysroot-ios-arm64` v5.0.8 CI artifact, SHA-256
`d200793cd39b77c459971e024ae37603ea8b47f0cd813240141f0afb9ef40811`.
Current frontend source compiled and linked with that sysroot. No native
dependency build was substituted. Required Xcode Metal Toolchain 27B47 was
installed. Henge's restore libraries, pairing library and patched StikJIT were
built from source; existing iOS networking archives were reused. CMake and
rustup were installed with Homebrew; Rust 1.100.0 and Cargo state are isolated
under `work/henge-toolchains`. Compile-heavy stages used at most two workers.

Henge's local patch is `scripts/patches/henge-research.patch`: SDK isolation
for Mac sample compilation, two-job restore build, dependency notices in the
app, an explicit research JIT cache override, and guest-only install/status
automation. The pinned source is checked before applying it. The UTM clone
has no application-source edits; its signing configuration is local/ignored.

Signed artifacts:

- `distribution/utm-full/UTM.app` and `UTM-research-signed.ipa`.
  ID `com.thomas20090425.research.UTM`, with its provisioned iOS helper.
  IPA SHA-256 `f02534161816cafb2a6a1ffaccc89bcb804604be694a761438f26e8e34e24764`.
- `distribution/henge-macos/Henge.app` and `Henge-research-signed.ipa`.
  IPA SHA-256 `727b8a3617b8adda46558b9520ff7e51516d540f4767042bf2b47efcb2a7c3b4`.
- `distribution/reservation-fixed-original/WindowsiOS.app` and development
  IPA contain the latest Windows settings/hub build. This update is staged.

App signatures, embedded capability/profile grants and IPA integrity were
checked. UTM and Henge receipts and dependency/license notices accompany their
artifacts. Open-source build receipts do not grant distribution rights to
the separate Apple restore image or guest disk.

Rebuild using an appropriate local signing team and fresh output paths:

```sh
DEVELOPMENT_TEAM=V3C22X6SVS ./scripts/build_utm_reference.sh
DEVELOPMENT_TEAM=V3C22X6SVS ./scripts/build_henge_reference.sh
```

The UTM script accepts `UTM_SYSROOT_ZIP` for the pinned CI download, or uses an
authenticated GitHub CLI to obtain it. Henge's script verifies its source
patch, builds its dependencies and writes a separate output directory. Both
scripts preserve existing outputs and never install or launch a device.

## Using the installed Mac

Finish Setup Assistant directly in Henge on the iPad. Keep Henge in the
foreground while the guest is running. Its VM files live in its own Documents
container; the original Windows files are separate.

For a later development launch, shut macOS down normally before terminating
Henge. This explicit command launches the matching installed app and prepares
JIT; it does not queue a guest restore or account setup:

```sh
./scripts/launch_henge_on_device.sh DEVICE_ID distribution/henge-macos/Henge.app
```

Once JIT is ready, tap ResearchMac's Start control in Henge. The launcher
relaunches the app, so do not run it over an active guest with unsaved work.
`scripts/henge_control.py` is an explicit research-only USB guest controller;
normal use does not require it. No automatic commands are currently queued.

For the original Windows app update, first shut its Windows guest down
normally, then install the staged update as an update without deleting the app.
The new Engines hub detects the two companion apps through their registered
URL schemes. Their libraries remain separate.
