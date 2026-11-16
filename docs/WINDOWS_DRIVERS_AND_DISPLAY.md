# Windows ARM64 networking and display

The app bundles unmodified **NetKVM** network and **viogpudo** display-only
drivers from official virtio-win **0.1.302-1**, driver version
**100.103.104.30200**. Their SYS/EXE files have ARM64 PE machine `0xAA64`.
Catalog metadata contains Microsoft publisher certificates; Windows performs
the final signature/trust check when installing them. No test certificate,
signature-enforcement change or Windows OS image is included.

`scripts/prepare_windows_drivers.py` downloads the pinned
[official package](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302-1.noarch.rpm)
with SHA-256
`2f58eea024e0221a873032761dc3ed3262409cd80860b7b27d3d5a0f206616c9`.
It checks the selected package bytes and creates a read-only FAT16 image,
license and manifest in `build/WindowsDrivers`, which is bundled with the app.
The driver image is always attached as USB storage LUN2, including VMs with no
installation ISO. The Windows volume label is **WINIOSDRVS**.

For new ISO installations, the app adds its guarded answer file to a private
copy of that image. Windows Setup's documented
[PnpCustomizationsWinPE driver paths](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-pnpcustomizationswinpe)
stage the ARM64 packages in the installed system. The specialize pass runs the
marked driver medium's installer to copy the packages permanently and install
the official `vgpusrv` resolution service. Driver/service failures are logged
and do not abort Windows installation. Existing disks never receive formatting
answers.

For an existing Windows installation, open **WINIOSDRVS**, right-click
**InstallDrivers.cmd**, and choose **Run as administrator** once. This installs
the network/display drivers and resolution service from the bundled packages.
Restart Windows if prompted. The log is
`%ProgramData%\WindowsiOS\DriverInstall.log`; installed packages/helpers are in
`%ProgramFiles%\WindowsiOS Drivers`. Existing VMs need no OS reinstall.

If Windows shows a fixed **800×600** screen alongside the adjustable VirtIO
screen, run the updated **InstallDrivers.cmd** once after updating the app.
It also installs a display-selection helper and runs it at each interactive
Windows sign-in. To fix the current desktop alone, run **UseVirtioDisplay.cmd**
on WINIOSDRVS. The helper selects the connected `VEN_1AF4&DEV_1050` adapter as
the sole active desktop and preserves its current resolution when available.
It leaves the topology unchanged if that adapter is unavailable. The firmware
adapter remains installed for boot/recovery, but its desktop is disconnected.
Logs are in `%LOCALAPPDATA%\WindowsiOS\DisplaySetup.log`. Remove the
`WindowsiOSDisplay` value under
`HKLM\Software\Microsoft\Windows\CurrentVersion\Run` to stop selection at sign-in.

Enable NAT in the VM settings. Windows then uses the iPad's network connection
through libslirp, with guest DHCP `10.0.2.15`, gateway `10.0.2.2` and DNS
`10.0.2.3`. Link/backend readiness does not establish successful Internet
traffic. Network behavior has not been measured on a device in this session.

The guest display now uses a real VirtIO GPU 2D device: resources, backing
transfers, scanout, cursor, EDID and display-change interrupts. **Accelerated
3D/DirectX and Apple GPU passthrough are unavailable.** Metal presents the
resulting framebuffer; Windows uses software rendering for 3D workloads.

Choose **Native screen**, **Fit app window**, or a preset from 1280×720 through
3840×2160. Native uses the connected display's physical pixels and orientation;
preferred dimensions are limited to 4095 per axis by the base EDID timing.
Larger native displays are fitted to that limit. Fit app window uses the
viewport's pixel size, with a minimum 640×480. With **Follow screen or window
changes** enabled, resizing/rotation updates the preferred mode, and the
official Windows service applies guest resolution changes. Windows remains
responsible for the active mode and also exposes Display Settings.

The firmware keeps its existing linear RAMFB boot console. Its initial mode
can be 800×600; selected/native modes become available when Windows loads the
VirtIO display driver. The GPU subsystem ID is deliberately `0x0010` so this
pinned firmware's Virtio10 driver skips its BLT-only GOP. The signed Windows
INF has a generic `VEN_1AF4&DEV_1050` match and can bind afterward. See
[EDK2 discovery](https://github.com/tianocore/edk2/blob/edk2-stable202502/OvmfPkg/Virtio10Dxe/Virtio10.c#L1021-L1040)
and [VirtIO GPU GOP](https://github.com/tianocore/edk2/blob/edk2-stable202502/OvmfPkg/VirtioGpuDxe/Gop.c).
This separate boot console can remain a second BasicDisplay desktop after the
driver loads, as described in [the upstream ARM64 report](https://github.com/virtio-win/kvm-guest-drivers-windows/issues/969).
The bundled helper uses [Windows display configuration](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setdisplayconfig)
to activate only VirtIO rather than removing the firmware device.

The iPad guest viewport fills the screen. Its floating **F keys** button opens
F1–F12 as an overlay with a hide arrow. Opening it does not resize Windows or
request a different guest mode; **Typing keyboard** remains a separate control.

The virtual CPU is reported consistently as **Arm Cortex-A76 r4p1 (virtual)**
in the app, SMBIOS and `MIDR_EL1` (`0x414fd0b1`), with matching device-tree
identity. The nominal clock is virtual accounting, not a host performance
measurement.

These are source/build results. No driver, guest, simulator, debugger or VM
was executed during implementation. Actual Internet access, driver trust,
Windows boot, native modes and dynamic resizing remain device-unverified.
