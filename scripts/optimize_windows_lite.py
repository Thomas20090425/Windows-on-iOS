#!/opt/homebrew/bin/python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
Optional offline Windows 11 24H2 ARM64 consumer-app and visual cleanup.
Creates work/windows11_lite.img from the user's source image; does not run as
part of the app build. Defender, SmartScreen, Windows Update, code integrity,
and CPU vulnerability mitigations are preserved. No performance gain is claimed.
The legacy opt_hive_arm64.exe helper is deliberately not invoked: it disables
security services and mitigations. Existing images are never overwritten.
"""

import os
import plistlib
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "work"
ESD = WORK / "downloads" / "Win11_24H2_ARM64_en-us.esd"
WINVM = ROOT / "build" / "winvm"
CODE_FD = WORK / "code.fd"
SRC_IMG = WORK / "windows11.img"
LITE_IMG = WORK / "windows11_lite.img"
PE_IMG = WORK / "_opt_pe.img"
PE_VARS = WORK / "_opt_pe_vars.fd"

OPT_SYS_REG = r"""Windows Registry Editor Version 5.00

; Windows security, service startup, mitigations and memory policy stay at defaults.
"""

OPT_SOFT_REG = r"""Windows Registry Editor Version 5.00

; Keep Edge available, but avoid launching it before the user opens it.
[HKEY_LOCAL_MACHINE\OFFSOFT\Policies\Microsoft\Edge]
"StartupBoostEnabled"=dword:00000000
"BackgroundModeEnabled"=dword:00000000
"""


def make_user_reg(hive_name: str) -> str:
    return rf"""Windows Registry Editor Version 5.00

; --- Disable CPU-Rendered DWM Mica/Acrylic Blur Shaders ---
[HKEY_LOCAL_MACHINE\{hive_name}\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize]
"EnableTransparency"=dword:00000000

; --- Best Performance Visual Effects (Crisp ClearType Fonts Kept!) ---
[HKEY_LOCAL_MACHINE\{hive_name}\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects]
"VisualFXSetting"=dword:00000003

[HKEY_LOCAL_MACHINE\{hive_name}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced]
"TaskbarAnimations"=dword:00000000
"ListviewAlphaSelect"=dword:00000000
"ListviewShadow"=dword:00000000
"IconsOnly"=dword:00000000
"TaskbarDa"=dword:00000000
"ShowCopilotButton"=dword:00000000
"ShowTaskViewButton"=dword:00000000
"LaunchTo"=dword:00000001

[HKEY_LOCAL_MACHINE\{hive_name}\Control Panel\Desktop]
"UserPreferencesMask"=hex:90,12,03,80,10,00,00,00
"FontSmoothing"="2"
"FontSmoothingType"=dword:00000002
"MenuShowDelay"="0"
"DragFullWindows"="0"

[HKEY_LOCAL_MACHINE\{hive_name}\Control Panel\Desktop\WindowMetrics]
"MinAnimate"="0"

; --- Disable Start Menu Bing WebView2 & Silent Content Delivery ---
[HKEY_LOCAL_MACHINE\{hive_name}\Software\Microsoft\Windows\CurrentVersion\Search]
"BingSearchEnabled"=dword:00000000
"CortanaConsent"=dword:00000000

[HKEY_LOCAL_MACHINE\{hive_name}\Software\Policies\Microsoft\Windows\Explorer]
"DisableSearchBoxSuggestions"=dword:00000001

[HKEY_LOCAL_MACHINE\{hive_name}\Software\Policies\Microsoft\Windows\WindowsCopilot]
"TurnOffWindowsCopilot"=dword:00000001

[HKEY_LOCAL_MACHINE\{hive_name}\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager]
"ContentDeliveryAllowed"=dword:00000000
"OemPreInstalledAppsEnabled"=dword:00000000
"PreInstalledAppsEnabled"=dword:00000000
"PreInstalledAppsEverEnabled"=dword:00000000
"SilentInstalledAppsEnabled"=dword:00000000
"SystemPaneSuggestionsEnabled"=dword:00000000
"SubscribedContent-338388Enabled"=dword:00000000
"SubscribedContent-338389Enabled"=dword:00000000
"SubscribedContent-338393Enabled"=dword:00000000
"SubscribedContent-353694Enabled"=dword:00000000
"SubscribedContent-353696Enabled"=dword:00000000

[HKEY_LOCAL_MACHINE\{hive_name}\Software\Microsoft\Windows\CurrentVersion\Run]
"OneDriveSetup"=-
"OneDrive"=-
"""


STARTNET_CMD = r"""@echo off
setlocal EnableDelayedExpansion
wpeinit

(
  echo automount enable
  echo select volume 0
  echo assign noerr
  echo select volume 1
  echo assign noerr
  echo select volume 2
  echo assign noerr
  echo select volume 3
  echo assign noerr
  echo select volume 4
  echo assign noerr
  echo select volume 5
  echo assign noerr
  echo list volume
) > X:\mount.txt
diskpart /s X:\mount.txt > X:\mount.log 2>&1

set "ESPDRV="
for %%E in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%E:\EFI_HOLD\Microsoft\Boot\bootmgfw.efi" (
        set "ESPDRV=%%E:"
    )
)

set "LOGFILE=X:\opt_progress.log"
if not "%ESPDRV%"=="" set "LOGFILE=%ESPDRV%\EFI_HOLD\opt_progress.log"

echo ===================================================================== > "%LOGFILE%"
echo   Windows 11 ARM64 Windows 11 24H2 Optional Consumer-App Cleanup >> "%LOGFILE%"
echo ===================================================================== >> "%LOGFILE%"
type X:\mount.log >> "%LOGFILE%"

set "WINDRV="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%D:\Windows\System32\ntoskrnl.exe" (
        set "WINDRV=%%D:"
    )
)

if "%WINDRV%"=="" (
    echo [FATAL] Could not find Windows NTFS volume! >> "%LOGFILE%"
    wpeutil shutdown
    exit /b 1
)

echo [1/5] Found Windows 11 installation on %WINDRV%\ (ESP=%ESPDRV%) >> "%LOGFILE%"
echo [2/5] Stripping 25 consumer inbox Appx bloatware bundles... >> "%LOGFILE%"
set /a REMOVED_COUNT=0
for %%P in (
    Clipchamp.Clipchamp_3.1.11920.0_neutral_~_yxz26nhyzhsrt
    MSTeams_1.0.0.0_arm64__8wekyb3d8bbwe
    Microsoft.BingNews_4.1.24002.0_neutral_~_8wekyb3d8bbwe
    Microsoft.BingSearch_2022.1.33.0_neutral_~_8wekyb3d8bbwe
    Microsoft.BingWeather_4.54.63017.0_neutral_~_8wekyb3d8bbwe
    Microsoft.GetHelp_10.2407.22193.0_neutral_~_8wekyb3d8bbwe
    Microsoft.MicrosoftOfficeHub_18.2409.1301.0_neutral_~_8wekyb3d8bbwe
    Microsoft.MicrosoftSolitaireCollection_4.22.3190.0_neutral_~_8wekyb3d8bbwe
    Microsoft.MicrosoftStickyNotes_6.1.5.0_neutral_~_8wekyb3d8bbwe
    Microsoft.OutlookForWindows_1.0.0.0_neutral__8wekyb3d8bbwe
    Microsoft.Todos_2.120.7961.0_neutral_~_8wekyb3d8bbwe
    Microsoft.Windows.DevHome_0.1701.597.0_neutral_~_8wekyb3d8bbwe
    Microsoft.WindowsAlarms_2021.2501.7.0_neutral_~_8wekyb3d8bbwe
    Microsoft.WindowsCamera_2022.2408.1.0_neutral_~_8wekyb3d8bbwe
    Microsoft.WindowsFeedbackHub_2024.125.1522.0_neutral_~_8wekyb3d8bbwe
    Microsoft.WindowsSoundRecorder_2021.2502.0.0_neutral_~_8wekyb3d8bbwe
    Microsoft.Xbox.TCUI_1.23.28005.0_neutral_~_8wekyb3d8bbwe
    Microsoft.XboxGamingOverlay_7.225.4030.0_neutral_~_8wekyb3d8bbwe
    Microsoft.XboxIdentityProvider_12.110.15002.0_neutral_~_8wekyb3d8bbwe
    Microsoft.XboxSpeechToTextOverlay_1.111.30001.0_neutral_~_8wekyb3d8bbwe
    Microsoft.YourPhone_1.25011.62.0_neutral_~_8wekyb3d8bbwe
    Microsoft.ZuneMusic_11.2501.9.0_neutral_~_8wekyb3d8bbwe
    MicrosoftCorporationII.QuickAssist_2025.331.2057.0_neutral_~_8wekyb3d8bbwe
    MicrosoftWindows.Client.WebExperience_524.30502.30.9_neutral_~_cw5n1h2txyewy
    MicrosoftWindows.CrossDevice_1.25011.11.0_neutral_~_cw5n1h2txyewy
) do (
    echo   - Removing %%P >> "%LOGFILE%"
    dism /Image:%WINDRV%\ /ScratchDir:X:\ /Remove-ProvisionedAppxPackage /PackageName:%%P /Quiet /NoRestart >> "%LOGFILE%" 2>&1
    if not errorlevel 1 set /a REMOVED_COUNT+=1
)
echo [2/5] Removed !REMOVED_COUNT! provisioned consumer Appx packages! >> "%LOGFILE%"

echo [3/5] Applying optional visual and background-launch preferences... >> "%LOGFILE%"
reg load HKLM\OFFSYS "%WINDRV%\Windows\System32\config\SYSTEM" >> "%LOGFILE%" 2>&1
reg load HKLM\OFFSOFT "%WINDRV%\Windows\System32\config\SOFTWARE" >> "%LOGFILE%" 2>&1
reg import X:\Windows\System32\opt_sys.reg >> "%LOGFILE%" 2>&1
reg import X:\Windows\System32\opt_soft.reg >> "%LOGFILE%" 2>&1
reg unload HKLM\OFFSOFT >> "%LOGFILE%" 2>&1
reg unload HKLM\OFFSYS >> "%LOGFILE%" 2>&1

echo [4/5] Applying zero-blur instant-UI settings to Ammaar and Default user hives... >> "%LOGFILE%"
if exist "%WINDRV%\Users\Ammaar\NTUSER.DAT" (
    reg load HKLM\OFFUSR "%WINDRV%\Users\Ammaar\NTUSER.DAT" >> "%LOGFILE%" 2>&1
    reg import X:\Windows\System32\opt_usr.reg >> "%LOGFILE%" 2>&1
    reg unload HKLM\OFFUSR >> "%LOGFILE%" 2>&1
)
if exist "%WINDRV%\Users\Default\NTUSER.DAT" (
    reg load HKLM\OFFDEF "%WINDRV%\Users\Default\NTUSER.DAT" >> "%LOGFILE%" 2>&1
    reg import X:\Windows\System32\opt_def.reg >> "%LOGFILE%" 2>&1
    reg unload HKLM\OFFDEF >> "%LOGFILE%" 2>&1
)

echo [5/5] Preserving system binaries, security settings and swap files. >> "%LOGFILE%"

echo RemovedAppx=!REMOVED_COUNT! > "%WINDRV%\LiteOptDone.txt"
if not "%ESPDRV%"=="" echo RemovedAppx=!REMOVED_COUNT! > "%ESPDRV%\EFI_HOLD\LiteOptDone.txt"
echo [DONE] Optional consumer-app cleanup complete (removed !REMOVED_COUNT! Appx packages)! Shutting down WinPE... >> "%LOGFILE%"
wpeutil shutdown
goto :eof
"""


def run(cmd, **kwargs):
    print(f"+ {' '.join(str(c) for c in cmd)}", flush=True)
    return subprocess.run([str(c) for c in cmd], check=True, **kwargs)


def toggle_efi_boot_folder(img_path: Path, hide: bool):
    """Temporarily rename /EFI <-> /EFI_HOLD on the image's FAT32 ESP so EDK2 boots secondary WinPE."""
    out = subprocess.check_output(
        ["hdiutil", "attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", str(img_path)],
        text=True,
    )
    whole_disk = out.strip().splitlines()[0].split()[0]
    esp_dev = f"{whole_disk}s1"
    try:
        run(["diskutil", "mount", esp_dev])
        info_plist = subprocess.check_output(["diskutil", "info", "-plist", esp_dev])
        mp = Path(plistlib.loads(info_plist)["MountPoint"])
        efi_dir = mp / "EFI"
        hold_dir = mp / "EFI_HOLD"
        if hide:
            if efi_dir.exists():
                if hold_dir.exists():
                    shutil.rmtree(hold_dir)
                efi_dir.rename(hold_dir)
                print(f"[esp] Renamed {efi_dir} -> {hold_dir}", flush=True)
        else:
            if hold_dir.exists():
                if efi_dir.exists():
                    shutil.rmtree(efi_dir)
                hold_dir.rename(efi_dir)
                print(f"[esp] Restored {hold_dir} -> {efi_dir}", flush=True)
        if not hide and not (mp / "EFI" / "Microsoft" / "Boot" / "bootmgfw.efi").exists():
            raise RuntimeError(f"Missing bootmgfw.efi on {mp} after restoring ESP!")
    finally:
        subprocess.run(["hdiutil", "detach", whole_disk], check=False)


def build_opt_winpe():
    print(f"Building compact bootable WinPE optimizer disk at {PE_IMG}...", flush=True)
    PE_IMG.unlink(missing_ok=True)
    with open(PE_IMG, "wb") as f:
        f.truncate(2200 * 1024 * 1024)

    out = subprocess.check_output(
        ["hdiutil", "attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", str(PE_IMG)],
        text=True,
    )
    whole_disk = out.strip().splitlines()[0].split()[0]
    try:
        run(["diskutil", "partitionDisk", whole_disk, "GPT", "MS-DOS", "OPTPE", "R"])
        pe_root = Path("/Volumes/OPTPE")
        if not pe_root.exists():
            raise RuntimeError("Expected /Volumes/OPTPE")

        stage = WORK / "_stage_opt_pe"
        shutil.rmtree(stage, ignore_errors=True)
        stage.mkdir(parents=True, exist_ok=True)
        run(["/opt/homebrew/bin/wimlib-imagex", "extract", ESD, "1", "/efi", "/boot", "/bootmgr.efi", f"--dest-dir={stage}"])
        for item in stage.iterdir():
            dest = pe_root / item.name
            if item.is_dir():
                shutil.copytree(item, dest, dirs_exist_ok=True)
            else:
                shutil.copy2(item, dest)

        boot_wim = pe_root / "sources" / "boot.wim"
        boot_wim.parent.mkdir(parents=True, exist_ok=True)
        run(["/opt/homebrew/bin/wimlib-imagex", "export", ESD, "2", boot_wim, "--compress=none", "--boot"])

        files = {
            "startnet.cmd": STARTNET_CMD,
            "opt_sys.reg": OPT_SYS_REG,
            "opt_soft.reg": OPT_SOFT_REG,
            "opt_usr.reg": make_user_reg("OFFUSR"),
            "opt_def.reg": make_user_reg("OFFDEF"),
        }
        wim_cmds = []
        for name, content in files.items():
            p = stage / name
            p.write_bytes(content.replace("\r\n", "\n").replace("\n", "\r\n").encode("ascii"))
            wim_cmds.append(f"add '{p}' '/Windows/System32/{name}'")

        run(
            ["/opt/homebrew/bin/wimlib-imagex", "update", boot_wim, "1"],
            input=("\n".join(wim_cmds) + "\n").encode("utf-8"),
        )
        shutil.rmtree(stage, ignore_errors=True)
    finally:
        subprocess.run(["hdiutil", "detach", whole_disk], check=False)


def run_winpe_optimizer():
    shutil.copyfile("/opt/homebrew/share/qemu/edk2-arm-vars.fd", PE_VARS)
    cmd_file = WORK / "_opt_pe.cmds"
    log_file = WORK / "_opt_pe.log"
    shot_file = WORK / "_opt_pe_screen.png"
    cmd_file.write_text("")

    cmd = [
        str(WINVM),
        "--headless",
        "--code", str(CODE_FD),
        "--vars", str(PE_VARS),
        "--disk", str(LITE_IMG),
        "--disk1", str(PE_IMG),
        "--cpus", "4",
        "--ram", "4096",
        "--no-net",
        "--cmd-file", str(cmd_file),
        "--screenshot", str(shot_file),
    ]
    print(f"=== Booting WinPE Optimizer: {' '.join(cmd)} ===", flush=True)
    t0 = time.time()
    env = os.environ.copy()
    env["HV_FLUSH"] = "1"
    with open(log_file, "wb") as lf:
        proc = subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT, env=env)
        next_shot = 15
        while proc.poll() is None:
            elapsed = time.time() - t0
            if elapsed >= next_shot:
                with open(cmd_file, "a", encoding="utf-8") as cf:
                    cf.write(f"screenshot {shot_file}\n")
                print(f"[opt-winpe +{int(elapsed)}s] running...", flush=True)
                next_shot += 20
            if elapsed > 25 * 60:
                proc.terminate()
                raise TimeoutError("WinPE optimizer exceeded 25 minutes")
            time.sleep(2)
        if proc.returncode != 0:
            raise RuntimeError(f"WinPE exited with {proc.returncode}; see {log_file}")
    print(f"=== WinPE Optimizer finished cleanly in {int(time.time() - t0)}s! ===", flush=True)


def main():
    if not SRC_IMG.exists():
        sys.exit(f"Missing {SRC_IMG}")
    if not ESD.exists():
        sys.exit(f"Missing {ESD}")
    if not WINVM.exists():
        sys.exit(f"Missing {WINVM}")

    print(f"Cloning {SRC_IMG} -> {LITE_IMG} via APFS copy-on-write...", flush=True)
    if LITE_IMG.exists():
        sys.exit(f"Refusing to overwrite {LITE_IMG}; choose a backup location first.")
    run(["cp", "-c", SRC_IMG, LITE_IMG])

    build_opt_winpe()
    toggle_efi_boot_folder(LITE_IMG, hide=True)
    try:
        run_winpe_optimizer()
    finally:
        toggle_efi_boot_folder(LITE_IMG, hide=False)
        PE_IMG.unlink(missing_ok=True)
        PE_VARS.unlink(missing_ok=True)
        (WORK / "_opt_pe.cmds").unlink(missing_ok=True)

    print(f"SUCCESS: Windows 11 24H2 ARM64 cleanup image ready at {LITE_IMG}!", flush=True)


if __name__ == "__main__":
    main()
