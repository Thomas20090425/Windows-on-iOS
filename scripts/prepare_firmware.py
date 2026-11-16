#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Stage pinned, redistributable EDK2 firmware as native application resources.

This is a build-time download/extraction step, not an emulator or a VM test.
Windows media is never downloaded. Per-machine writable NVRAM is copied from
the paired vendor template by the app; the bundled template stays immutable.
"""

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PACKAGE_VERSION = "2025.02-8+deb13u1"
PACKAGE_NAME = f"qemu-efi-aarch64_{PACKAGE_VERSION}_all.deb"
PACKAGE_URL = f"https://deb.debian.org/debian/pool/main/e/edk2/{PACKAGE_NAME}"
PACKAGE_SHA256 = "a00b2411a79c8aeafd95a7c868ac3cd1aab592f1af9fff965f02d81a625276ed"
CHECKSUM_SOURCE = "https://packages.debian.org/trixie/all/qemu-efi-aarch64/download"
SOURCE_URL = "https://sources.debian.org/src/edk2/2025.02-8%2Bdeb13u1/"
CACHE = ROOT / "work" / "firmware"
OUTPUT = ROOT / "build" / "firmware" / "Firmware"
FLASH_BYTES = 64 * 1024 * 1024

# Select the explicit Secure Boot build and its Microsoft-enrolled paired
# variable template. Never select the package's insecure snakeoil images/keys.
ASSETS = {
    "usr/share/AAVMF/AAVMF_CODE.secboot.fd": "code.fd",
    "usr/share/AAVMF/AAVMF_VARS.ms.fd": "vars-template.fd",
    "usr/share/doc/qemu-efi-aarch64/copyright": "EDK2-LICENSES.txt",
    "usr/share/doc/qemu-efi-aarch64/README.Debian": "README.Debian.txt",
}


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def package_data_archive(path):
    """Read the data member of a Debian ar archive without running package code."""
    with path.open("rb") as stream:
        if stream.read(8) != b"!<arch>\n":
            raise RuntimeError("Invalid Debian package archive")
        while True:
            header = stream.read(60)
            if not header:
                break
            if len(header) != 60 or header[58:] != b"`\n":
                raise RuntimeError("Invalid Debian archive member")
            name = header[:16].decode("ascii").strip().rstrip("/")
            size = int(header[48:58].decode("ascii").strip())
            payload = stream.read(size)
            if len(payload) != size:
                raise RuntimeError("Truncated Debian archive")
            if size % 2:
                stream.read(1)
            if name in {"data.tar.xz", "data.tar.gz"}:
                return payload
    raise RuntimeError("Debian package has no supported data archive")


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    package = CACHE / PACKAGE_NAME
    if not package.exists() or sha256_file(package) != PACKAGE_SHA256:
        temporary = CACHE / f"{PACKAGE_NAME}.download"
        try:
            subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--output", str(temporary), PACKAGE_URL], check=True)
            if sha256_file(temporary) != PACKAGE_SHA256:
                raise RuntimeError("EDK2 package SHA-256 does not match the pinned Debian checksum")
            os.replace(temporary, package)
        finally:
            temporary.unlink(missing_ok=True)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".firmware-", dir=OUTPUT.parent))
    try:
        hashes = {}
        with tarfile.open(fileobj=io.BytesIO(package_data_archive(package)), mode="r:*") as archive:
            members = {member.name.removeprefix("./"): member for member in archive.getmembers()}
            for source_name, output_name in ASSETS.items():
                member = members.get(source_name)
                if member is None or not member.isfile():
                    raise RuntimeError(f"Missing regular firmware resource: {source_name}")
                if output_name.endswith(".fd") and member.size != FLASH_BYTES:
                    raise RuntimeError(f"Firmware flash bank must contain exactly {FLASH_BYTES} bytes")
                destination = staging / output_name
                with archive.extractfile(member) as source, destination.open("wb") as target:
                    shutil.copyfileobj(source, target, length=1024 * 1024)
                hashes[output_name] = sha256_file(destination)

        manifest = {
            "upstream": "TianoCore EDK2 ArmVirtQemu AARCH64",
            "distribution": "Debian qemu-efi-aarch64",
            "package_version": PACKAGE_VERSION,
            "package_url": PACKAGE_URL,
            "package_sha256": PACKAGE_SHA256,
            "published_checksum_url": CHECKSUM_SOURCE,
            "corresponding_source_url": SOURCE_URL,
            "flash_bank_bytes": FLASH_BYTES,
            "secure_boot": "Microsoft certificates enrolled in the fresh variable template",
            "files_sha256": hashes,
            "runtime_validation": "NOT RUN: build resources only",
        }
        (staging / "provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
        OUTPUT.mkdir(parents=True, exist_ok=True)
        # Do not rewrite unchanged resources during incremental builds.
        for source in staging.iterdir():
            destination = OUTPUT / source.name
            if destination.exists() and sha256_file(destination) == sha256_file(source):
                continue
            os.replace(source, destination)
        print(f"Bundled EDK2 {PACKAGE_VERSION}: {OUTPUT}")
    finally:
        shutil.rmtree(staging)


if __name__ == "__main__":
    main()
