# UTM configuration reference and WindowsiOS mapping

The latest request supersedes the separate-app interface described below:
use UTM's actual frontend and embed both native engines in one app. See
[UTM ARM Lab](UNIFIED_UTM.md) for that implementation and validation status.

Reviewed on 2026-11-15. UTM's official documentation and current public configuration source were used as design references. No UTM source code was copied. WindowsiOS continues to use its existing ARM64 translator and virtual hardware; it does not embed QEMU, SPICE, Apple's Virtualization framework or UTM.

Later the same day, the user requested a full source-backed UTM/macOS
experiment. Pinned UTM was cloned, built with official native dependencies,
signed and installed as a separate companion. Source-built Henge restored and
booted Sequoia on the M5 iPad with Metal replay. WindowsiOS now has nine
settings pages, draft Save/Cancel, notes/search and an Engines hub. The table
below still describes the Windows engine's capabilities; arbitrary `.utm`
handling belongs to the installed full UTM app. See
[research results](VIRTUALIZATION_RESEARCH.md) for actual runtime evidence and
the separate-app boundary.

## Configuration structure

UTM separates system, input, sharing, displays, drives, networking, serial and sound configuration into Codable models. Its argument builder translates those models into QEMU options. The useful architectural pattern is a persisted model validated and translated at the execution boundary. WindowsiOS now follows that pattern with `VMConfiguration`, `configuration.json`, `configureMachineDirectory` and `configureRuntimeOptions`. Existing configurations receive default values for newly introduced fields. See [UTM configuration model](https://github.com/utmapp/UTM/blob/main/Configuration/UTMQemuConfiguration.swift) and [argument generation](https://github.com/utmapp/UTM/blob/main/Configuration/UTMQemuConfiguration%2BArguments.swift).

## Implemented mapping

| Area | UTM reference | WindowsiOS implementation and boundary |
| --- | --- | --- |
| System | [Memory, CPU and JIT cache](https://docs.getutm.app/settings-qemu/system/) | Persist 1–4 vCPUs and a custom whole-MiB RAM allowance from 4096 MiB to the current device limit, retaining 3 GiB host headroom. Software TPM 2.0 uses libtpms with per-VM persistent state. Architecture, CPU identity and JIT cache size remain fixed because this engine is ARM64-specific. |
| Drives | [Drive guide](https://docs.getutm.app/settings-qemu/drive/drive/) and [drive model](https://github.com/utmapp/UTM/blob/main/Configuration/UTMQemuConfigurationDrive.swift) | Normal setup imports a Windows ARM64 ISO, creates a 64–512 GiB sparse writable NVMe disk and private NVRAM, uses bundled EDK2, and attaches a genuine USB MSC optical drive plus a removable answer disk. Advanced legacy imports accept prepared raw/HVSPARSE disks and an optional read-only second NVMe disk. No QCOW2/VHDX conversion, resizing or live disk replacement is offered. |
| Networking | [Network modes](https://docs.getutm.app/settings-qemu/devices/network/network/) and [network model](https://github.com/utmapp/UTM/blob/main/Configuration/UTMQemuConfigurationNetwork.swift) | Enable or disable the existing libslirp NAT device. A single TCP forward can bind iPad loopback host port 1024–65535 to guest port 1–65535; both zero disables it. No bridged, host-only, arbitrary adapter/MAC, UDP-forward or custom DHCP/DNS editor is exposed. |
| Sharing | [Shared directories](https://docs.getutm.app/settings-qemu/sharing/) | Toggle the existing `Documents/Shared` WebDAV server at `http://10.0.2.4/`, reachable through guest networking. This is WindowsiOS's server, not UTM's SPICE WebDAV channel. Clipboard synchronization, VirtFS and USB device passthrough are unavailable. |
| Display | [Display settings](https://docs.getutm.app/settings-qemu/devices/display/) | Native-screen, window-fit and fixed preferred modes use the new VirtIO GPU 2D/EDID path. Included ARM64 viogpudo and the official resolution service handle guest changes. Keep RAMFB for firmware boot. Host 30/60/120 Hz presentation and pinch zoom remain separate. No accelerated 3D, GPU passthrough or multiple guest monitors. |
| Input | [USB/input](https://docs.getutm.app/settings-qemu/input/) | Preserve the fixed xHCI HID keyboard and absolute tablet. Store touch-trackpad mode, Command-to-Control mapping and relative-pointer sensitivity per machine. Native hardware events use the existing USB path. |
| Audio | Existing engine HDA/RemoteIO path | Separate speaker and microphone controls; microphone defaults off for newly configured machines and still requires iPadOS permission. No arbitrary sound-card selector is offered. |
| Diagnostics | [QEMU logging reference](https://docs.getutm.app/settings-qemu/qemu/) | Expose the existing engine's logging switch and live native diagnostics. These are WindowsiOS logs, not QEMU logs. |

UTM's [port-forwarding guide](https://docs.getutm.app/settings-qemu/devices/network/port-forwarding/) also recommends loopback as the default host interface. WindowsiOS restricts this first configuration surface to loopback TCP and one mapping.

## Remaining gaps and validation

A `.utm` bundle/configuration cannot be imported directly: its device and backend parameters do not describe this runtime. Normal setup needs only the user's Windows 11 ARM64 ISO; the build supplies redistributable EDK2 firmware and its matching variable template. Snapshot, suspend/resume, arbitrary boot-device editing and safe in-process VM replacement require complete engine-state lifecycle support before being exposed. A real software TPM 2.0 is now linked through libtpms; its firmware/Windows handoff and the ISO installation path remain runtime-unverified.

These controls are connected to actual native configuration paths. This review establishes a source-level mapping, not proof of JIT availability, guest boot, input, disk writes, audio or networking on an iPad. Per the user's instruction, verification in this session is limited to compilation; no tests, VM execution, profiling or debugging are performed on the Mac.
