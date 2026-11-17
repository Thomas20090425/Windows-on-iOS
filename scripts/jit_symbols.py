#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Read local Mach-O metadata for device JIT launch; never execute the app."""

import argparse
import json
from pathlib import Path
import plistlib
import struct
import uuid

REQUIRED = (
    "winios_jit_helper_token", "winios_brk_probe_trap",
    "winios_brk_mapping_trap", "winios_brk_detach_trap",
)
BOOTSTRAP = "winios_jit_install_trap_handler"
CPU_ARM64 = 0x0100000C


def read_image(path, include_symbols=True):
    """Return unslid addresses from an arm64 executable or Debug dylib."""
    raw = Path(path).read_bytes()
    offset, size = 0, len(raw)
    if raw[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        fat64 = raw[:4] == b"\xca\xfe\xba\xbf"
        count = struct.unpack_from(">I", raw, 4)[0]
        entry_size = 32 if fat64 else 20
        for index in range(count):
            entry = 8 + index * entry_size
            cpu = struct.unpack_from(">I", raw, entry)[0]
            if cpu != CPU_ARM64:
                continue
            fmt = ">QQ" if fat64 else ">II"
            offset, size = struct.unpack_from(fmt, raw, entry + 8)
            break
        else:
            raise ValueError(f"No arm64 image in {path}")
    if offset + size > len(raw) or size < 32:
        raise ValueError(f"Invalid Mach-O extent: {path}")
    data = memoryview(raw)[offset:offset + size]
    magic, cpu, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<IiiIIIII", data)
    if magic != 0xFEEDFACF or cpu != CPU_ARM64 or 32 + sizeofcmds > size:
        raise ValueError(f"Expected arm64 Mach-O: {path}")
    cursor, image_uuid, text_vmaddr, symtab = 32, None, None, None
    sections = []
    for _ in range(ncmds):
        if cursor + 8 > 32 + sizeofcmds:
            raise ValueError(f"Truncated Mach-O load commands: {path}")
        cmd, length = struct.unpack_from("<II", data, cursor)
        if length < 8 or cursor + length > 32 + sizeofcmds:
            raise ValueError(f"Invalid Mach-O command size: {path}")
        if cmd == 0x1B and length >= 24:  # LC_UUID
            image_uuid = str(uuid.UUID(bytes=bytes(data[cursor + 8:cursor + 24]))).upper()
        elif cmd == 0x19 and length >= 72:  # LC_SEGMENT_64
            segment = struct.unpack_from("<II16sQQQQiiII", data, cursor)
            if segment[2].rstrip(b"\0") == b"__TEXT":
                text_vmaddr = segment[3]
            section_count = segment[9]
            if 72 + section_count * 80 > length:
                raise ValueError(f"Invalid Mach-O sections: {path}")
            for index in range(section_count):
                section = cursor + 72 + index * 80
                address, extent = struct.unpack_from("<QQ", data, section + 32)
                sections.append({"address": address, "size": extent, "writable": bool(segment[8] & 2)})
        elif cmd == 2 and length >= 24:  # LC_SYMTAB
            symtab = struct.unpack_from("<IIII", data, cursor + 8)
        cursor += length
    if image_uuid is None or text_vmaddr is None:
        raise ValueError(f"Mach-O UUID or __TEXT missing: {path}")
    symbols = {}
    if symtab and include_symbols:
        symoff, nsyms, stroff, strsize = symtab
        if symoff + nsyms * 16 > size or stroff + strsize > size:
            raise ValueError(f"Invalid Mach-O symbol table: {path}")
        strings = bytes(data[stroff:stroff + strsize])
        for index in range(nsyms):
            name_offset, kind, section, _, value = struct.unpack_from("<IBBHQ", data, symoff + 16 * index)
            if kind & 0xE0 or kind & 0x0E != 0x0E or not 1 <= section <= len(sections):
                continue  # Only defined section symbols; never undefined/absolute addresses.
            if name_offset >= strsize:
                continue
            end = strings.find(b"\0", name_offset)
            if end < 0:
                continue
            name = strings[name_offset:end].decode("utf-8", errors="replace").removeprefix("_")
            if name not in (*REQUIRED, BOOTSTRAP):
                continue
            bounds = sections[section - 1]
            width = 8 if name == REQUIRED[0] else 4
            if not bounds["address"] <= value <= bounds["address"] + bounds["size"] - width:
                raise ValueError(f"JIT symbol lies outside its section: {name}")
            if name == REQUIRED[0] and (value % 8 or not bounds["writable"]):
                raise ValueError("JIT readiness word must be aligned writable data")
            symbols[name] = value
    return {"path": str(Path(path).resolve()), "uuid": image_uuid,
            "text_vmaddr": text_vmaddr, "symbols": symbols}


def build_manifest(app, bundle_id=None):
    app = Path(app).expanduser().resolve()
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    identifier = info["CFBundleIdentifier"]
    if bundle_id and bundle_id != identifier:
        raise ValueError(f"Local app bundle ID {identifier} does not match {bundle_id}")
    executable = app / info["CFBundleExecutable"]
    # Xcode Debug can use a tiny executable plus a separately loaded debug
    # dylib. Both UUIDs matter; Release addresses cannot be reused for Debug.
    paths = [executable, *sorted(app.glob("*.debug.dylib"))]
    backend = app / 'Frameworks/WindowsBackend.framework/WindowsBackend'
    if backend.is_file():
        paths.append(backend)
    images = [read_image(path) for path in paths]
    if not any(all(name in image["symbols"] for name in REQUIRED) for image in images):
        raise ValueError(f"This local app lacks current JIT helper symbols: {app}. Rebuild it or pass APP_PATH pointing to the matching current .app.")
    symbol_files = {}
    root = Path(__file__).resolve().parent.parent
    for image in images:
        # Only explicit nearby build products are considered, never Spotlight
        # or recursive disk/network searches. A dSYM is optional and UUID-bound.
        candidates = [app.parent / (app.name + ".dSYM") / "Contents/Resources/DWARF" / Path(image["path"]).name]
        for configuration in ("Release", "Debug"):
            candidates.append(root / "build/DerivedData/Build/Products" / (configuration + "-iphoneos") /
                              (app.name + ".dSYM") / "Contents/Resources/DWARF" / Path(image["path"]).name)
        for candidate in candidates:
            if not candidate.is_file():
                continue
            try:
                if read_image(candidate, include_symbols=False)["uuid"] == image["uuid"]:
                    symbol_files[image["uuid"]] = str(candidate.resolve())
                    break
            except (ValueError, OSError, struct.error):
                continue
    return {"version": 1, "app": str(app), "bundle_identifier": identifier,
            "executable": str(executable), "images": images, "symbol_files": symbol_files}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--bundle-id")
    args = parser.parse_args()
    try:
        manifest = build_manifest(args.app, args.bundle_id)
        output = Path(args.output)
        output.write_text(json.dumps(manifest, indent=2) + "\n")
    except (OSError, KeyError, ValueError, struct.error) as error:
        parser.exit(1, f"JIT symbol preflight: {error}\n")


if __name__ == "__main__":
    main()
