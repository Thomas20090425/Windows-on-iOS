#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Launch Henge and own its UUID-checked Mac JIT transport; import is read-only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time

from jit_symbols import read_image
from _launch_mac_jit import ROOT, free_port, hardware_udid, lldb_quote, start_forwarder, stop_child

ROUTINES = {"henge_brk_probe": (0, 0x69), "henge_brk_get_jit_mapping": (4, 0xF00D),
            "henge_brk_jit_detach": (4, 0xF00D), "henge_ios_jit_install_trap_handler": (0, None)}


def image_metadata(path):
    image = read_image(path, include_symbols=False)
    output = subprocess.check_output(["xcrun", "nm", "-arch", "arm64", "-n", "-U", str(path)], text=True)
    symbols = {}
    for line in output.splitlines():
        match = re.fullmatch(r"\s*([0-9a-fA-F]+)\s+[Tt]\s+_(\w+)\s*", line)
        if match and match[2] in ROUTINES:
            symbols[match[2]] = int(match[1], 16) + ROUTINES[match[2]][0]
    image["symbols"] = symbols
    image["sha256"] = hashlib.sha256(Path(path).read_bytes()).hexdigest()
    return image


def build_manifest(app, bundle_id=None):
    app = Path(app).expanduser().resolve()
    info = plistlib.loads((app / "Info.plist").read_bytes())
    identifier, name = info["CFBundleIdentifier"], info["CFBundleExecutable"]
    if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9.-]+", identifier):
        raise ValueError("Invalid local app bundle identifier")
    if bundle_id and bundle_id != identifier:
        raise ValueError("Requested bundle identifier does not match the local app")
    if not isinstance(name, str) or Path(name).name != name or not name:
        raise ValueError("Invalid local app executable name")
    executable = app / name
    paths = [executable, *sorted(app.glob("*.debug.dylib"))]
    backend = app / 'Frameworks/HengeBackend.framework/HengeBackend'
    if backend.is_file():
        paths.append(backend)
    images = [image_metadata(p) for p in paths]
    if not any(all(key in image["symbols"] for key in ROUTINES) for image in images):
        raise ValueError("Local Henge app lacks the defined JIT/bootstrap symbols; rebuild without stripping them")
    return {"version": 1, "app": str(app), "bundle_identifier": identifier,
            "executable": str(executable), "images": images}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--bundle-id")
    parser.add_argument("--preflight", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9-]+", args.device):
        parser.error("Invalid device identifier")
    manifest = build_manifest(args.app, args.bundle_id)
    if args.preflight:
        print(f"[henge-jit] Local symbol preflight passed: {manifest['bundle_identifier']}")
        return
    timeout = int(os.environ.get("HENGE_JIT_TIMEOUT", "1800"))
    if not 60 <= timeout <= 7200:
        raise ValueError("HENGE_JIT_TIMEOUT must be 60 through 7200 seconds")
    forwarder = proxy = debugger = None
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        (ROOT / "work").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="henge-jit-", dir=ROOT / "work") as folder:
            directory = Path(folder)
            symbols = directory / "symbols.json"
            symbols.write_text(json.dumps(manifest, indent=2))
            launch = directory / "launch.json"
            launch_environment = {"HENGE_AUTOPILOT": "1", "HENGE_CODE_CACHE_MB": "512"}
            if (Path(manifest['app']) / 'Frameworks/HengeBackend.framework').is_dir():
                launch_environment = {"UTM_NATIVE_ENGINE": "macOSARM64", "HENGE_CODE_CACHE_MB": "512"}
            subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--start-stopped",
                            "--terminate-existing", "--device", args.device, "--json-output", str(launch),
                            "--environment-variables", json.dumps(launch_environment),
                            manifest["bundle_identifier"]], check=True)
            data = json.loads(launch.read_text())["result"]
            pid = data["process"]["processIdentifier"]
            if not isinstance(pid, int) or pid <= 0:
                raise ValueError("Device launch did not return a valid PID")
            device = data.get("device", {}).get("identifier") or args.device
            if not re.fullmatch(r"[A-Za-z0-9-]+", device):
                raise ValueError("Device launch returned an invalid device identifier")
            udid = hardware_udid(device, directory)
            upstream = free_port()
            log = ROOT / "build/logs/henge-jit-transport.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            forwarder = start_forwarder(udid, upstream, log)
            ready = directory / "proxy-ready.json"
            proxy = subprocess.Popen([sys.executable, "-u", str(ROOT / "scripts/jit_rsp_proxy.py"),
                                      "--upstream-port", str(upstream), "--local-port", "0", "--ready-file", str(ready)])
            deadline = time.monotonic() + 10
            while not ready.exists():
                if proxy.poll() is not None or forwarder.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError(f"Henge JIT proxy did not become ready; see {log}")
                time.sleep(0.05)
            port = json.loads(ready.read_text())["port"]
            if not isinstance(port, int) or not 0 < port <= 65535:
                raise ValueError("Invalid JIT proxy port")
            attached, completed = directory / "attached", directory / "jit-ready"
            commands = directory / "launch.lldb"
            commands.write_text("\n".join([
                "script lldb.debugger.SetAsync(False)",
                "command script import " + lldb_quote(ROOT / "scripts/_lldb_txm_jit.py"),
                "command script import " + lldb_quote(ROOT / "scripts/_lldb_henge_jit.py"),
                "script import _lldb_txm_jit; _lldb_txm_jit.configure_symbol_lookup(lldb.debugger)",
                "settings set plugin.process.gdb-remote.packet-timeout 300",
                "platform select remote-ios", "target create " + lldb_quote(manifest["executable"]),
                f"txm_jit_attach {port} {pid}", "henge_jit_run", ""]))
            environment = os.environ.copy()
            environment.update(WINIOS_JIT_PREPARE="proxy", WINIOS_JIT_ATTACHED_FILE=str(attached),
                               HENGE_JIT_SYMBOLS_JSON=str(symbols), HENGE_JIT_READY_FILE=str(completed),
                               PYTHONPATH=str(ROOT / "scripts"))
            print(f"[henge-jit] Attaching to PID {pid}; using the exact local Henge build.", flush=True)
            debugger = subprocess.Popen(["xcrun", "lldb", "-b", "-s", str(commands)], env=environment)
            start = time.monotonic()
            while debugger.poll() is None:
                if forwarder.poll() is not None or proxy.poll() not in (None, 0):
                    raise RuntimeError(f"Henge debug transport disconnected; see {log}")
                elapsed = time.monotonic() - start
                if not attached.exists() and elapsed > 60:
                    raise RuntimeError("Henge debugger attachment exceeded 60 seconds")
                if elapsed > timeout:
                    raise RuntimeError("Henge JIT setup exceeded its bounded timeout")
                time.sleep(0.1)
            if debugger.returncode or not completed.exists():
                raise RuntimeError("Henge JIT setup did not complete; inspect the debugger error above")
            print("[henge-jit] JIT mapping prepared and debugger detached. Guest RAM and macOS startup are separate steps.")
    finally:
        for child in (debugger, proxy, forwarder):
            stop_child(child)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("[henge-jit] Stopped; close Henge before a fresh JIT launch.", file=sys.stderr)
        sys.exit(130)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"[henge-jit] {error}", file=sys.stderr)
        sys.exit(1)
