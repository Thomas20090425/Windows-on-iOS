# UTM configuration reference and WindowsiOS mapping

Reviewed on 2026-11-15. UTM's official documentation and current public configuration source were used as design references. No UTM source code was copied. WindowsiOS continues to use its existing ARM64 translator and virtual hardware; it does not embed QEMU, SPICE, Apple's Virtualization framework or UTM.

## Configuration structure

UTM separates system, input, sharing, displays, drives, networking, serial and sound configuration into Codable models. Its argument builder translates those models into QEMU options. The useful architectural pattern is a persisted model validated and translated at the execution boundary. WindowsiOS now follows that pattern with `VMConfiguration`, `configuration.json`, `configureMachineDirectory` and `configureRuntimeOptions`. Existing configurations receive default values for newly introduced fields. See [UTM configuration model](https://github.com/utmapp/UTM/blob/main/Configuration/UTMQemuConfiguration.swift) and [argument generation](https://github.com/utmapp/UTM/blob/main/Configuration/UTMQemuConfiguration%2BArguments.swift).

## Implemented mapping

| Area | UTM reference | WindowsiOS implementation and boundary |
| --- | --- | --- |
| System | [Memory, CPU and JIT cache](https://docs.getutm.app/settings-qemu/system/) | Persist 1–4 vCPUs and 4–4.5 GiB guest RAM; native admission checks retain host headroom. Architecture, CPU identity and JIT cache size remain fixed because this engine is ARM64-specific. |
| Drives | [Drive guide](https://docs.getutm.app/settings-qemu/drive/drive/) and [drive model](https://github.com/utmapp/UTM/blob/main/Configuration/UTMQemuConfigurationDrive.swift) | Normal setup imports a Windows ARM64 ISO, creates a 64–512 GiB sparse writable NVMe disk and private NVRAM, uses bundled EDK2, and attaches a genuine USB MSC optical drive plus a removable answer disk. Advanced legacy imports accept prepared raw/HVSPARSE disks and an optional read-only second NVMe disk. No QCOW2/VHDX conversion, resizing or live disk replacement is offered. |
| Networking | [Network modes](https://docs.getutm.app/settings-qemu/devices/network/network/) and [network model](https://github.com/utmapp/UTM/blob/main/Configuration/UTMQemuConfigurationNetwork.swift) | Enable or disable the existing libslirp NAT device. A single TCP forward can bind iPad loopback host port 1024–65535 to guest port 1–65535; both zero disables it. No bridged, host-only, arbitrary adapter/MAC, UDP-forward or custom DHCP/DNS editor is exposed. |
| Sharing | [Shared directories](https://docs.getutm.app/settings-qemu/sharing/) | Toggle the existing `Documents/Shared` WebDAV server at `http://10.0.2.4/`, reachable through guest networking. This is WindowsiOS's server, not UTM's SPICE WebDAV channel. Clipboard synchronization, VirtFS and USB device passthrough are unavailable. |
| Display | [Display settings](https://docs.getutm.app/settings-qemu/devices/display/) | Choose a host Metal presentation limit of 30, 60 or 120 Hz. Guest framebuffer resolution remains controlled by guest firmware/Windows. Host pinch zoom, panning and aspect-fit resizing do not change guest resolution. No virtual GPU model selector, 3D acceleration, dynamic guest resizing or multiple guest monitors is claimed. |
| Input | [USB/input](https://docs.getutm.app/settings-qemu/input/) | Preserve the fixed xHCI HID keyboard and absolute tablet. Store touch-trackpad mode, Command-to-Control mapping and relative-pointer sensitivity per machine. Native hardware events use the existing USB path. |
| Audio | Existing engine HDA/RemoteIO path | Separate speaker and microphone controls; microphone defaults off for newly configured machines and still requires iPadOS permission. No arbitrary sound-card selector is offered. |
| Diagnostics | [QEMU logging reference](https://docs.getutm.app/settings-qemu/qemu/) | Expose the existing engine's logging switch and live native diagnostics. These are WindowsiOS logs, not QEMU logs. |

UTM's [port-forwarding guide](https://docs.getutm.app/settings-qemu/devices/network/port-forwarding/) also recommends loopback as the default host interface. WindowsiOS restricts this first configuration surface to loopback TCP and one mapping.

## Remaining gaps and validation

A `.utm` bundle/configuration cannot be imported directly: its device and backend parameters do not describe this runtime. Normal setup needs only the user's Windows 11 ARM64 ISO; the build supplies redistributable EDK2 firmware and its matching variable template. Snapshot, suspend/resume, arbitrary boot-device editing and safe in-process VM replacement require complete engine-state lifecycle support before being exposed. There is no virtual TPM, so Windows Setup may reject the platform; the new ISO installation path is compiled but not runtime-verified.

These controls are connected to actual native configuration paths. This review establishes a source-level mapping, not proof of JIT availability, guest boot, input, disk writes, audio or networking on an iPad. Per the user's instruction, verification in this session is limited to compilation; no tests, VM execution, profiling or debugging are performed on the Mac.
