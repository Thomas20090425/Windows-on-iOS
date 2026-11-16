# SPDX-License-Identifier: GPL-2.0-or-later
# Keep the firmware boot console available, but use only the VirtIO desktop.
# CCD requires the interactive desktop; the installer only registers -Install.
[CmdletBinding()]
param(
    [switch]$Install,
    [ValidateRange(0, 120)]
    [int]$RetrySeconds = 60
)

$ErrorActionPreference = 'Stop'
$logDirectory = Join-Path $env:LOCALAPPDATA 'WindowsiOS'
$logPath = Join-Path $logDirectory 'DisplaySetup.log'

function Write-DisplayLog([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        Add-Content -LiteralPath $logPath -Value $line -Encoding ASCII
    } catch {
        # A log write must not prevent a safe display change.
    }
    Write-Output $line
}

try {
    if ($Install) {
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $command = '"{0}" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -RetrySeconds 60' -f $powershell, $PSCommandPath
        $runKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (-not (Test-Path -LiteralPath $runKey)) {
            New-Item -Path $runKey | Out-Null
        }
        New-ItemProperty -Path $runKey -Name 'WindowsiOSDisplay' -PropertyType String -Value $command -Force | Out-Null
        Write-DisplayLog 'Registered VirtIO display setup for interactive sign-in. No display configuration was changed.'
        exit 0
    }

    if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
        Write-DisplayLog 'Skipped session 0: sign in to Windows or run UseVirtioDisplay.cmd from the desktop.'
        exit 0
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace WindowsiOS {
    public static class SingleDisplay {
        const uint QDC_ALL_PATHS = 1;
        const uint PATH_ACTIVE = 1;
        const uint MODE_INVALID = 0xffffffff;
        const uint MODE_SOURCE = 1;
        const uint MODE_TARGET = 2;
        const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x20;
        const uint SDC_VALIDATE = 0x40;
        const uint SDC_APPLY = 0x80;
        const uint SDC_SAVE_TO_DATABASE = 0x200;
        const uint SDC_ALLOW_CHANGES = 0x400;
        const int ERROR_INSUFFICIENT_BUFFER = 122;

        [StructLayout(LayoutKind.Sequential)]
        struct Luid { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)]
        struct Point { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)]
        struct Rational { public uint Numerator, Denominator; }
        [StructLayout(LayoutKind.Sequential)]
        struct SourceMode { public uint Width, Height, PixelFormat; public Point Position; }
        // The full native union is 48 bytes. Preserve target/desktop modes as
        // opaque data while allowing the source origin to be changed safely.
        [StructLayout(LayoutKind.Explicit, Size = 48)]
        struct ModeUnion {
            [FieldOffset(0)] public SourceMode Source;
            [FieldOffset(0)] public ulong A;
            [FieldOffset(8)] public ulong B;
            [FieldOffset(16)] public ulong C;
            [FieldOffset(24)] public ulong D;
            [FieldOffset(32)] public ulong E;
            [FieldOffset(40)] public ulong F;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct ModeInfo { public uint Type, Id; public Luid Adapter; public ModeUnion Mode; }
        [StructLayout(LayoutKind.Sequential)]
        struct SourceInfo { public Luid Adapter; public uint Id, ModeIndex, Status; }
        [StructLayout(LayoutKind.Sequential)]
        struct TargetInfo {
            public Luid Adapter;
            public uint Id, ModeIndex, OutputTechnology, Rotation, Scaling;
            public Rational RefreshRate;
            public uint ScanLineOrdering;
            [MarshalAs(UnmanagedType.Bool)] public bool Available;
            public uint Status;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct PathInfo { public SourceInfo Source; public TargetInfo Target; public uint Flags; }
        [StructLayout(LayoutKind.Sequential)]
        struct DeviceHeader { public uint Type, Size; public Luid Adapter; public uint Id; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct AdapterName {
            public DeviceHeader Header;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DevicePath;
        }

        [DllImport("user32.dll")]
        static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
        [DllImport("user32.dll")]
        static extern int QueryDisplayConfig(uint flags, ref uint pathCount,
            [Out] PathInfo[] paths, ref uint modeCount, [Out] ModeInfo[] modes, IntPtr topology);
        [DllImport("user32.dll")]
        static extern int DisplayConfigGetDeviceInfo(ref AdapterName request);
        [DllImport("user32.dll")]
        static extern int SetDisplayConfig(uint pathCount, [In] PathInfo[] paths,
            uint modeCount, [In] ModeInfo[] modes, uint flags);

        static bool SameAdapter(Luid a, Luid b) { return a.Low == b.Low && a.High == b.High; }

        static bool IsVirtio(Luid adapter) {
            AdapterName name = new AdapterName();
            name.Header.Type = 4; // DISPLAYCONFIG_DEVICE_INFO_GET_ADAPTER_NAME
            name.Header.Size = (uint)Marshal.SizeOf(typeof(AdapterName));
            name.Header.Adapter = adapter;
            if (DisplayConfigGetDeviceInfo(ref name) != 0 || name.DevicePath == null) return false;
            return Regex.IsMatch(name.DevicePath,
                @"(?:^|[\\#])PCI[\\#]VEN_1AF4&DEV_1050(?:&|[\\#]|$)", RegexOptions.IgnoreCase);
        }

        static bool ValidMode(ModeInfo[] modes, uint count, uint index, uint type, Luid adapter, uint id) {
            return index < count && modes[index].Type == type && modes[index].Id == id &&
                SameAdapter(modes[index].Adapter, adapter);
        }

        public static string Apply() {
            // Fail before calling CCD if a runtime marshals a native type differently.
            if (Marshal.SizeOf(typeof(PathInfo)) != 72 || Marshal.SizeOf(typeof(ModeInfo)) != 64 ||
                Marshal.SizeOf(typeof(AdapterName)) != 276)
                throw new InvalidOperationException("Unexpected Windows display API structure layout.");

            uint pathCount = 0, modeCount = 0;
            PathInfo[] paths = null;
            ModeInfo[] modes = null;
            int status = 0;
            // Topology may change between the size query and the data query.
            for (int attempt = 0; attempt < 5; attempt++) {
                status = GetDisplayConfigBufferSizes(QDC_ALL_PATHS, out pathCount, out modeCount);
                if (status != 0) return "WAIT: display enumeration returned " + status;
                if (pathCount == 0 || pathCount > 1024 || modeCount > 8192)
                    return "WAIT: no usable display paths yet";
                paths = new PathInfo[pathCount];
                modes = new ModeInfo[modeCount];
                status = QueryDisplayConfig(QDC_ALL_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
                if (status != ERROR_INSUFFICIENT_BUFFER) break;
            }
            if (status != 0) return "WAIT: display query returned " + status;

            int selected = -1, activeCount = 0;
            HashSet<string> targets = new HashSet<string>();
            for (int i = 0; i < pathCount; i++) {
                if ((paths[i].Flags & PATH_ACTIVE) != 0) activeCount++;
                if (!paths[i].Target.Available || !IsVirtio(paths[i].Target.Adapter)) continue;
                Luid adapter = paths[i].Target.Adapter;
                targets.Add(adapter.High + ":" + adapter.Low + ":" + paths[i].Target.Id);
                if (selected < 0 || (paths[i].Flags & PATH_ACTIVE) != 0) selected = i;
            }
            if (selected < 0) return "WAIT: a connected PCI VEN_1AF4 DEV_1050 display is not ready; configuration unchanged";
            if (targets.Count != 1) return "WAIT: more than one VirtIO output found; configuration unchanged";

            PathInfo path = paths[selected];
            bool wasActive = (path.Flags & PATH_ACTIVE) != 0;
            bool keepModes = wasActive &&
                ValidMode(modes, modeCount, path.Source.ModeIndex, MODE_SOURCE, path.Source.Adapter, path.Source.Id) &&
                ValidMode(modes, modeCount, path.Target.ModeIndex, MODE_TARGET, path.Target.Adapter, path.Target.Id);
            if (keepModes) {
                ModeInfo source = modes[path.Source.ModeIndex];
                if (activeCount == 1 && source.Mode.Source.Position.X == 0 && source.Mode.Source.Position.Y == 0)
                    return "OK: VirtIO is already the sole active desktop display";
                source.Mode.Source.Position.X = 0;
                source.Mode.Source.Position.Y = 0;
                ModeInfo target = modes[path.Target.ModeIndex];
                modes = new ModeInfo[] { source, target };
                modeCount = 2;
                path.Source.ModeIndex = 0;
                path.Target.ModeIndex = 1;
            } else {
                // Let Windows choose a supported preferred mode for an inactive
                // output; never reuse stale or virtual-mode packed indices.
                path.Source.ModeIndex = MODE_INVALID;
                path.Target.ModeIndex = MODE_INVALID;
                path.Target.RefreshRate = new Rational();
                path.Target.ScanLineOrdering = 0;
                modes = null;
                modeCount = 0;
            }
            path.Flags = PATH_ACTIVE;
            PathInfo[] singlePath = new PathInfo[] { path };
            uint common = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES;
            status = SetDisplayConfig(1, singlePath, modeCount, modes, common | SDC_VALIDATE);
            if (status != 0) return "WAIT: single VirtIO display validation returned " + status + "; configuration unchanged";
            status = SetDisplayConfig(1, singlePath, modeCount, modes,
                common | SDC_APPLY | SDC_SAVE_TO_DATABASE);
            if (status != 0) return "WAIT: single VirtIO display apply returned " + status;
            return "OK: saved VirtIO as the sole active desktop display; firmware adapter retained for boot";
        }
    }
}
'@

    $deadline = [DateTime]::UtcNow.AddSeconds($RetrySeconds)
    $previous = ''
    do {
        $result = [WindowsiOS.SingleDisplay]::Apply()
        if ($result -ne $previous) { Write-DisplayLog $result; $previous = $result }
        if ($result.StartsWith('OK:')) { exit 0 }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 2
    } while ($true)
    Write-DisplayLog 'Display setup timed out without applying a VirtIO-only configuration. See the status above.'
    exit 2
} catch {
    Write-DisplayLog ('Display setup failed: ' + $_.Exception.Message)
    exit 1
}
