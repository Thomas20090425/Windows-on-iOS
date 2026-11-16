#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Package pinned, unmodified Windows ARM64 drivers into a FAT16 data disk.

This is build-time data preparation only. It never executes a Windows binary,
boots an image, attaches a debugger, or changes guest driver-signing policy.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
VERSION = "0.1.302-1"
ARCHIVE_NAME = f"virtio-win-{VERSION}.noarch.rpm"
URL = ("https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/"
       f"archive-virtio/virtio-win-{VERSION}/{ARCHIVE_NAME}")
ARCHIVE_SHA256 = "2f58eea024e0221a873032761dc3ed3262409cd80860b7b27d3d5a0f206616c9"
OFFICIAL_MD5 = "66f65c16ab3e8dfe12c2855a0d1ac303"
DRIVER_VERSION = "100.103.104.30200"
PAYLOAD_SHA256 = {
    "NetKVM/netkvm.cat": "c5fa8b6790e9c0dac8fd8848c617292230ecaba29a03cf1ad25bdf243970a722",
    "NetKVM/netkvm.inf": "4b56c2e399c5b1943a1e8bae5b4907ca06ebc76053df5cfdc628bcf68fa371fd",
    "NetKVM/netkvm.sys": "118e6c7cad6f09b406f2b58dc9592ccbe1e803e751e5577b66ac180dbeacaabb",
    "NetKVM/netkvmco.exe": "ba1be928cbb05e57299c99f9d15be7c09fb754d2f096a74b806aa8a7bffa8fa8",
    "NetKVM/netkvmp.exe": "6abd66a785e0edd00ce91c09b207d3e67f5567d32cadd44c7d3363a9b1381a37",
    "viogpudo/vgpusrv.exe": "f85b5cc9b92d76b7f66060217b7bbafe7a3a72fc01e892e175baa6fa867cce3e",
    "viogpudo/viogpuap.exe": "6aa7e950721299d9303651030ff72ef8e10adbfc5077bcc333b8416fb3ef7f35",
    "viogpudo/viogpudo.cat": "15a9b4664470602ab20efe1d665dc98d5fe0337e32038bc51369ecc0ca4826d2",
    "viogpudo/viogpudo.inf": "849cfefa9364b4a3e80dd44ce898e3b4766af5c4a475ea0a95ddb4c9f1cb2e4b",
    "viogpudo/viogpudo.sys": "78bf0afc614a19c365a050e96e0d0274def2ac860e842cc0964795bf431a14b7",
    "viogpudo/viogpures.exe": "f5ed8835069cb0ebce2c3a07d919019040671f8ff08fd4248574cb924c5cf6a8",
    "LICENSE": "accd84cb35eff899d619ff40e6fea8074305cdf0e7191db71a5d9c3a015e3b02",
}


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            result.update(block)
    return result.hexdigest()


def payload_path(extracted, name):
    if name == "LICENSE":
        return extracted / "usr/share/doc/virtio-win/virtio-win_license.txt"
    driver, filename = name.split("/")
    return extracted / "usr/share/virtio-win/drivers/by-driver" / driver / "w11/ARM64" / filename


def payloads_match(extracted):
    return all(payload_path(extracted, name).is_file() and
               digest(payload_path(extracted, name)) == expected
               for name, expected in PAYLOAD_SHA256.items())


def prepare_source(work):
    work.mkdir(parents=True, exist_ok=True)
    archive = work / ARCHIVE_NAME
    if not archive.exists():
        print(f"[drivers] Downloading official virtio-win {VERSION} RPM", flush=True)
        temporary = archive.with_suffix(archive.suffix + ".part")
        try:
            with urllib.request.urlopen(URL, timeout=60) as response, temporary.open("wb") as target:
                if not response.geturl().startswith("https://"):
                    raise RuntimeError("Refusing a non-HTTPS driver download redirect")
                shutil.copyfileobj(response, target, 1 << 20)
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    if digest(archive) != ARCHIVE_SHA256:
        raise RuntimeError(f"Driver archive checksum mismatch; remove {archive} and retry")
    extracted = work / "extracted"
    if not payloads_match(extracted):
        unpacker = shutil.which("bsdtar") or shutil.which("tar")
        if not unpacker:
            raise RuntimeError("Driver packaging requires libarchive bsdtar (brew install libarchive)")
        print("[drivers] Extracting ARM64 packages; no driver is executed", flush=True)
        with tempfile.TemporaryDirectory(prefix="driver-extract-", dir=work) as temporary:
            staging = Path(temporary)
            subprocess.run([unpacker, "-xf", str(archive), "-C", str(staging),
                            "--include", "*/drivers/by-driver/*/*/ARM64/*",
                            "--include", "*/drivers/by-os/ARM64/*",
                            "--include", "*/doc/virtio-win/virtio-win_license.txt",
                            "--exclude", "*.pdb", "--exclude", "*.md"], check=True)
            if not payloads_match(staging):
                raise RuntimeError("The official archive does not contain the pinned ARM64 driver payloads")
            if extracted.exists():
                shutil.rmtree(extracted)
            staging.rename(extracted)
    return extracted


def validate_arm64(name, data):
    if len(data) < 64 or data[:2] != b"MZ":
        raise RuntimeError(f"{name} is not a Windows PE image")
    offset = struct.unpack_from("<I", data, 60)[0]
    if offset + 24 > len(data) or data[offset:offset + 4] != b"PE\0\0":
        raise RuntimeError(f"{name} has an invalid PE header")
    if struct.unpack_from("<H", data, offset + 4)[0] != 0xAA64:
        raise RuntimeError(f"{name} is not ARM64; it will not be bundled")


class Node:
    def __init__(self, name, data=None, parent=None):
        self.name, self.data, self.parent = name, data, parent
        self.children = []
        self.cluster = self.clusters = 0
        self.short = None
        self.long = False

    @property
    def directory(self):
        return self.data is None


def short_name(name, used):
    base, dot, extension = name.rpartition(".")
    if not dot:
        base, extension = name, ""
    simple = re.fullmatch(r"[A-Za-z0-9_-]{1,8}", base) and re.fullmatch(r"[A-Za-z0-9_-]{0,3}", extension)
    if simple:
        result = base.upper().ljust(8) + extension.upper().ljust(3)
        if result not in used:
            used.add(result)
            return result.encode("ascii"), False
    base = re.sub(r"[^A-Z0-9_]", "", base.upper()) or "FILE"
    extension = re.sub(r"[^A-Z0-9_]", "", extension.upper())[:3]
    for index in range(1, 1000):
        suffix = f"~{index}"
        result = (base[:8 - len(suffix)] + suffix).ljust(8) + extension.ljust(3)
        if result not in used:
            used.add(result)
            return result.encode("ascii"), True
    raise RuntimeError("Too many colliding FAT filenames")


def long_entries(name, short):
    checksum = 0
    for byte in short:
        checksum = (((checksum & 1) << 7) | (checksum >> 1)) + byte
        checksum &= 255
    encoded = name.encode("utf-16le") + b"\0\0"
    encoded += b"\xff\xff" * ((13 - len(encoded) // 2 % 13) % 13)
    chunks = [encoded[index:index + 26] for index in range(0, len(encoded), 26)]
    result = bytearray()
    for number in range(len(chunks), 0, -1):
        data = chunks[number - 1]
        entry = bytearray(32)
        entry[0] = number | (0x40 if number == len(chunks) else 0)
        entry[11], entry[13] = 0x0f, checksum
        entry[1:11], entry[14:26], entry[28:32] = data[:10], data[10:22], data[22:26]
        result.extend(entry)
    return bytes(result)


def entry(short, attributes, cluster, length):
    data = bytearray(32)
    data[:11], data[11] = short, attributes
    date = ((2026 - 1980) << 9) | (8 << 5) | 27
    struct.pack_into("<H", data, 16, date)
    struct.pack_into("<H", data, 18, date)
    struct.pack_into("<H", data, 24, date)
    struct.pack_into("<H", data, 26, cluster)
    struct.pack_into("<I", data, 28, length)
    return data


def build_fat16(files):
    """Return image and the reserved three-entry/64-KiB answer-file slot."""
    sector_bytes, cluster_bytes = 512, 2048
    total_sectors, fat_sectors, root_entries = 131072, 128, 512
    fat_offsets = [sector_bytes, sector_bytes * (1 + fat_sectors)]
    root_offset = sector_bytes * (1 + 2 * fat_sectors)
    data_offset = root_offset + root_entries * 32
    image = bytearray(total_sectors * sector_bytes)
    image[:11] = b"\xeb\x3c\x90WINIOS  "
    struct.pack_into("<HBHBHHBHHHII", image, 11, sector_bytes, 4, 1, 2, root_entries,
                     0, 0xf8, fat_sectors, 32, 64, 0, total_sectors)
    image[36:39] = b"\x80\x00\x29"
    struct.pack_into("<I", image, 39, 0x57494452)
    image[43:54], image[54:62] = b"WINIOSDRVS ", b"FAT16   "
    image[510:512] = b"\x55\xaa"
    fat = bytearray(fat_sectors * sector_bytes)
    struct.pack_into("<HH", fat, 0, 0xfff8, 0xffff)
    next_cluster = 2

    def allocate(count):
        nonlocal next_cluster
        first = next_cluster
        if data_offset + (first - 2 + count) * cluster_bytes > len(image):
            raise RuntimeError("Driver disk capacity exceeded")
        for cluster in range(first, first + count):
            struct.pack_into("<H", fat, cluster * 2, cluster + 1 if cluster < first + count - 1 else 0xffff)
        next_cluster += count
        return first

    config_cluster = allocate(65536 // cluster_bytes)
    root = Node("")
    for path, content in sorted(files.items()):
        current = root
        parts = path.split("/")
        for component in parts[:-1]:
            child = next((n for n in current.children if n.name == component), None)
            if child is None:
                child = Node(component, parent=current)
                current.children.append(child)
            current = child
        current.children.append(Node(parts[-1], content, parent=current))

    def assign(node):
        used = set()
        if node is root:
            used.add("CONFIG  BIN")
        for child in node.children:
            child.short, child.long = short_name(child.name, used)
        if node is not root:
            slots = 2 + sum(1 + (math.ceil((len(c.name.encode('utf-16le')) // 2 + 1) / 13) if c.long else 0)
                            for c in node.children)
            node.clusters = math.ceil((slots + 1) * 32 / cluster_bytes)
            node.cluster = allocate(node.clusters)
        for child in node.children:
            if child.directory:
                assign(child)
            elif child.data:
                child.clusters = math.ceil(len(child.data) / cluster_bytes)
                child.cluster = allocate(child.clusters)

    assign(root)

    def write_node(node):
        if not node.directory:
            if node.cluster:
                start = data_offset + (node.cluster - 2) * cluster_bytes
                image[start:start + len(node.data)] = node.data
            return
        listing = bytearray()
        if node is root:
            listing.extend(entry(b"WINIOSDRVS ", 0x08, 0, 0))
            # Deleted entries reserve exactly two LFN slots before CONFIG.BIN.
            listing.extend(b"\xe5" + bytes(31))
            listing.extend(b"\xe5" + bytes(31))
            listing.extend(entry(b"CONFIG  BIN", 0x20, config_cluster, 65536))
        else:
            listing.extend(entry(b".          ", 0x10, node.cluster, 0))
            listing.extend(entry(b"..         ", 0x10, node.parent.cluster, 0))
        for child in node.children:
            if child.long:
                listing.extend(long_entries(child.name, child.short))
            listing.extend(entry(child.short, 0x10 if child.directory else 0x20,
                                 child.cluster, 0 if child.directory else len(child.data)))
            write_node(child)
        start = root_offset if node is root else data_offset + (node.cluster - 2) * cluster_bytes
        capacity = root_entries * 32 if node is root else node.clusters * cluster_bytes
        if len(listing) + 32 > capacity:
            raise RuntimeError("FAT directory capacity exceeded")
        image[start:start + len(listing)] = listing

    write_node(root)
    for offset in fat_offsets:
        image[offset:offset + len(fat)] = fat
    slot = {
        "root_entry_offset": root_offset + 32, "root_entry_slots": 3,
        "short_entry_offset": root_offset + 96,
        "data_offset": data_offset + (config_cluster - 2) * cluster_bytes,
        "first_cluster": config_cluster, "cluster_bytes": cluster_bytes,
        "max_bytes": 65536, "fat_offsets": fat_offsets,
    }
    return image, slot


INSTALL_COMMAND = r"""@echo off
setlocal
set "SOURCE=%~dp0"
set "LOGDIR=%ProgramData%\WindowsiOS"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
if errorlevel 1 exit /b 1
set "MODE=manual"
if /I "%~1"=="/setup" set "MODE=setup"
call :install >>"%LOGDIR%\DriverInstall.log" 2>&1
set "RC=%errorlevel%"
echo Driver installation result: %RC%. Log: %LOGDIR%\DriverInstall.log
endlocal & exit /b %RC%

:install
echo ==== WindowsiOS ARM64 drivers %DATE% %TIME% mode=%MODE% ====
fltmc >nul 2>&1
if errorlevel 1 (
  echo Right-click InstallDrivers.cmd and choose Run as administrator.
  exit /b 1
)
set "DEST=%ProgramFiles%\WindowsiOS Drivers"
if not exist "%DEST%" mkdir "%DEST%"
if errorlevel 1 exit /b 1
if not exist "%DEST%\Drivers\NetKVM" mkdir "%DEST%\Drivers\NetKVM"
if errorlevel 1 exit /b 1
if not exist "%DEST%\Drivers\Display" mkdir "%DEST%\Drivers\Display"
if errorlevel 1 exit /b 1
__COPY_COMMANDS__
call :copyfile "%SOURCE%LICENSE.TXT" "%DEST%\LICENSE.TXT"
if errorlevel 1 exit /b 1
call :copyfile "%SOURCE%UseVirtioDisplay.ps1" "%DEST%\UseVirtioDisplay.ps1"
if errorlevel 1 exit /b 1
call :copyfile "%SOURCE%UseVirtioDisplay.cmd" "%DEST%\UseVirtioDisplay.cmd"
if errorlevel 1 exit /b 1
pnputil /add-driver "%DEST%\Drivers\NetKVM\netkvm.inf" /install
set "RC=%errorlevel%"
if not "%RC%"=="0" if not "%RC%"=="3010" exit /b %RC%
pnputil /add-driver "%DEST%\Drivers\Display\viogpudo.inf" /install
set "RC=%errorlevel%"
if not "%RC%"=="0" if not "%RC%"=="3010" exit /b %RC%
sc query vgpusrv >nul 2>&1
if errorlevel 1 "%DEST%\Drivers\Display\vgpusrv.exe" -i
sc query vgpusrv >nul 2>&1
if errorlevel 1 exit /b 1
sc qc vgpusrv
sc start vgpusrv
set "RC=%errorlevel%"
if not "%RC%"=="0" if not "%RC%"=="1056" exit /b %RC%
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%DEST%\UseVirtioDisplay.ps1" -Install
if errorlevel 1 exit /b 1
rem Windows Setup runs in session 0; select the desktop only in a user session.
if /I not "%MODE%"=="setup" (
  call "%DEST%\UseVirtioDisplay.cmd"
  if errorlevel 1 echo Display selection is pending; it will retry at the next sign-in.
)
echo Drivers and the official VirtIO resolution service are installed.
echo The VirtIO display is selected as the only desktop at each Windows sign-in.
echo Restart Windows if prompted, or if display resizing is not yet available.
echo Display is VirtIO GPU display-only; DirectX uses Windows software rendering.
exit /b 0

:copyfile
if not exist "%~2" goto copy
fc /b "%~1" "%~2" >nul 2>&1
if not errorlevel 1 exit /b 0
:copy
copy /b /y "%~1" "%~2"
if errorlevel 1 (
  echo Cannot copy "%~2". An older resolution service may still be using this file.
  echo Close other driver installers or stop the existing vgpusrv service before retrying.
  exit /b 1
)
exit /b 0
"""

_copy_commands = []
for _payload in PAYLOAD_SHA256:
    if _payload == "LICENSE":
        continue
    _driver, _filename = _payload.split("/")
    _folder = "NetKVM" if _driver == "NetKVM" else "Display"
    _relative = f"Drivers\\{_folder}\\{_filename}"
    _copy_commands.append(f'call :copyfile "%SOURCE%{_relative}" "%DEST%\\{_relative}"\nif errorlevel 1 exit /b 1')
INSTALL_COMMAND = INSTALL_COMMAND.replace("__COPY_COMMANDS__", "\n".join(_copy_commands))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/WindowsDrivers")
    args = parser.parse_args()
    extracted = prepare_source(ROOT / "work/windows-drivers")
    files = {}
    for name in PAYLOAD_SHA256:
        if name == "LICENSE":
            continue
        data = payload_path(extracted, name).read_bytes()
        driver, filename = name.split("/")
        if filename.endswith((".sys", ".exe")):
            validate_arm64(name, data)
        if filename.endswith(".inf") and b"NTARM64" not in data.upper():
            raise RuntimeError(f"{name} is not an ARM64 INF")
        destination = "NetKVM" if driver == "NetKVM" else "Display"
        files[f"Drivers/{destination}/{filename}"] = data
    license_bytes = payload_path(extracted, "LICENSE").read_bytes()
    files["LICENSE.TXT"] = license_bytes
    files["WINIOSDRIVERS.TAG"] = b"WindowsiOS signed ARM64 driver media v1\r\n"
    files["InstallDrivers.cmd"] = INSTALL_COMMAND.replace("\n", "\r\n").encode("ascii")
    for helper in ("UseVirtioDisplay.ps1", "UseVirtioDisplay.cmd"):
        source = (ROOT / "scripts/windows" / helper).read_text(encoding="ascii")
        files[helper] = source.replace("\n", "\r\n").encode("ascii")
    files["README.TXT"] = (
        "WindowsiOS Windows 11 ARM64 drivers\r\n"
        "NetKVM enables the virtual NAT Ethernet adapter.\r\n"
        "viogpudo supports the VirtIO GPU display-only adapter and dynamic modes.\r\n"
        "Run InstallDrivers.cmd as administrator in an existing Windows VM.\r\n"
        "It copies drivers/helpers into Program Files and installs the official VioGpu Resolution Service.\r\n"
        "The resolution helper remains on the Windows disk after this data disk is removed.\r\n"
        "It selects VirtIO as the only active desktop, disconnecting the fixed firmware screen.\r\n"
        "Run UseVirtioDisplay.cmd to repair display selection without reinstalling drivers.\r\n"
        "Selection is retried at sign-in; log: %LOCALAPPDATA%\\WindowsiOS\\DisplaySetup.log.\r\n"
        "Logs: %ProgramData%\\WindowsiOS\\DriverInstall.log. Matching installed files are retained.\r\n"
        "New ISO installations stage these signed packages through Windows Setup.\r\n"
        "No test certificate, test-signing mode or signature bypass is used.\r\n"
        "Windows performs final driver trust/hardware matching. Guest operation is not verified.\r\n"
        "CONFIG.BIN is reserved space; this base disk has no automatic installation answer.\r\n"
    ).encode("ascii")
    provenance = {
        "version": 1, "package": f"virtio-win-{VERSION}", "source": URL,
        "archive_sha256": ARCHIVE_SHA256, "upstream_checksum_md5": OFFICIAL_MD5,
        "driver_version": DRIVER_VERSION, "driver_date": "2026-07-22", "architecture": "ARM64",
        "drivers": {"network": "NetKVM", "display": "viogpudo (display-only, no 3D acceleration)"},
        "catalog_metadata": "Microsoft Windows Hardware Compatibility Publisher; Windows validates trust at installation",
        "signature_policy": "Unmodified official packages; no signature bypass or test certificate installed",
        "files_sha256": {path: hashlib.sha256(data).hexdigest() for path, data in sorted(files.items())},
        "validation": "Build-time PE/INF/catalog metadata and checksums only; no driver, debugger, device or VM execution",
    }
    files["PROVENANCE.JSON"] = (json.dumps(provenance, indent=2) + "\n").encode("utf-8")
    image, answer_slot = build_fat16(files)
    provenance["image_sha256"] = hashlib.sha256(image).hexdigest()
    provenance["image_bytes"] = len(image)
    provenance["answer_slot"] = answer_slot
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "drivers.img").write_bytes(image)
    (args.output / "LICENSE.TXT").write_bytes(license_bytes)
    (args.output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(f"[drivers] Packaged ARM64 NetKVM and viogpudo in {args.output / 'drivers.img'}", flush=True)


if __name__ == "__main__":
    main()
