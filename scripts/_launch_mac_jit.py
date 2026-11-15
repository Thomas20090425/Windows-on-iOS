#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Own the Mac debugproxy connection and LLDB lifetime for batched TXM setup.

Only launch_on_device.sh calls this, after an explicit owner launch. Merely
installing/compiling the scripts never opens a device or starts a debugger.
"""

import argparse
import json
import os
from pathlib import Path
import plistlib
import queue
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
HARDWARE_UDID = re.compile(r"(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{16}|[0-9a-fA-F]{40})\Z")


def hardware_udid(device, directory):
    """Map a CoreDevice UUID to this exact device's USB UDID, never the first USB device."""
    output = directory / "device-details.json"
    subprocess.run(["xcrun", "devicectl", "device", "info", "details", "--device", device,
                    "--json-output", str(output)], check=True)
    found = {}

    def visit(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if key.lower() == "udid" and isinstance(item, str) and HARDWARE_UDID.fullmatch(item):
                    found[item.casefold()] = item
                else:
                    visit(item)
        elif isinstance(value, list):
            for item in value:
                visit(item)

    visit(json.loads(output.read_text())["result"])
    explicit = os.environ.get("WINIOS_DEVICE_UDID")
    if explicit:
        if not HARDWARE_UDID.fullmatch(explicit):
            raise RuntimeError("WINIOS_DEVICE_UDID must be the hardware UDID, not a CoreDevice UUID")
        if found and set(found) != {explicit.casefold()}:
            raise RuntimeError("WINIOS_DEVICE_UDID does not match the selected CoreDevice device")
        return found.get(explicit.casefold(), explicit)
    if len(found) == 1:
        return next(iter(found.values()))
    if not found and HARDWARE_UDID.fullmatch(device):
        return device
    raise RuntimeError("Could not resolve the selected device's hardware UDID. Set WINIOS_DEVICE_UDID "
                       "to its UDID from Xcode's Devices window and rerun; no debugger was attached.")


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def read_lines(stream, messages):
    for line in stream:
        messages.put(line)
    messages.put(None)


def start_forwarder(udid, port, log_path):
    # Force the independent no-root USB userspace tunnel. This avoids opening
    # Apple's single native RSD session in competition with devicectl/remoted.
    environment = os.environ.copy()
    for name in ("PYMOBILEDEVICE3_TUNNEL", "PYMOBILEDEVICE3_NATIVE", "PYMOBILEDEVICE3_UDID"):
        environment.pop(name, None)
    environment.update(PYTHONUNBUFFERED="1", NO_COLOR="1")
    child = subprocess.Popen([sys.executable, "-m", "pymobiledevice3", "developer", "debugserver",
                              "start-server", "--udid", udid, "--userspace", "--local-port", str(port),
                              "--host", "127.0.0.1"], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, env=environment)
    messages = queue.Queue()
    threading.Thread(target=read_lines, args=(child.stdout, messages), daemon=True).start()
    deadline = time.monotonic() + 90
    next_report = time.monotonic() + 10
    recent = []
    with log_path.open("w") as log:
        try:
            while time.monotonic() < deadline:
                try:
                    line = messages.get(timeout=0.25)
                except queue.Empty:
                    if child.poll() is not None:
                        break
                    if time.monotonic() >= next_report:
                        print("[mac-jit] Waiting for the USB developer tunnel; keep the device unlocked and trusted.", flush=True)
                        next_report = time.monotonic() + 10
                    continue
                if line is None:
                    break
                log.write(line)
                log.flush()
                recent.append(line.rstrip())
                recent = recent[-12:]
                if "Started port forwarding." in line:
                    # The pinned CLI prints this immediately before binding.
                    # The proxy retries a refused upstream connection, without
                    # probing/creating an extra debugserver connection here.
                    threading.Thread(target=drain_log, args=(messages, log_path), daemon=True).start()
                    return child
            raise RuntimeError("USB debugproxy did not become ready. " + "\n".join(recent) +
                               f"\nTransport log: {log_path}")
        except BaseException:
            stop_child(child)
            raise


def drain_log(messages, log_path):
    # Logs contain tunnel status only; never enable packet logging of guest memory.
    with log_path.open("a") as log:
        while True:
            line = messages.get()
            if line is None:
                return
            log.write(line)
            log.flush()


def stop_child(child):
    if child is None:
        return
    if child.poll() is None:
        child.terminate()
    try:
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()


def lldb_quote(value):
    # LLDB command-file syntax, not shell interpolation.
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    if args.pid <= 0 or not re.fullmatch(r"[A-Za-z0-9-]+", args.device):
        parser.error("Invalid device/PID")
    args.app = args.app.resolve()
    info = plistlib.loads((args.app / "Info.plist").read_bytes())
    executable = args.app / info["CFBundleExecutable"]
    forwarder = proxy = debugger = None

    def interrupted(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    try:
        with tempfile.TemporaryDirectory(prefix="mac-jit-", dir=ROOT / "work") as folder:
            directory = Path(folder)
            udid = hardware_udid(args.device, directory)
            upstream_port = free_port()
            log_path = ROOT / "work" / "mac-jit-transport.log"
            print("[mac-jit] Opening the Mac USB batch transport (no StikDebug required).", flush=True)
            forwarder = start_forwarder(udid, upstream_port, log_path)
            ready = directory / "proxy-ready.json"
            proxy = subprocess.Popen([sys.executable, "-u", str(ROOT / "scripts" / "jit_rsp_proxy.py"),
                                      "--upstream-port", str(upstream_port), "--local-port", "0",
                                      "--ready-file", str(ready)])
            deadline = time.monotonic() + 10
            while not ready.exists():
                if proxy.poll() is not None:
                    raise RuntimeError("Mac batch proxy exited before listening")
                if forwarder.poll() is not None:
                    raise RuntimeError(f"USB debugproxy exited; see {log_path}")
                if time.monotonic() >= deadline:
                    raise RuntimeError("Mac batch proxy did not begin listening")
                time.sleep(0.05)
            port = json.loads(ready.read_text())["port"]
            if not isinstance(port, int) or not 0 < port <= 65535:
                raise RuntimeError("Invalid batch proxy port")
            commands = directory / "launch.lldb"
            commands.write_text("\n".join([
                "script lldb.debugger.SetAsync(False)",
                "command script import " + lldb_quote(ROOT / "scripts" / "_lldb_txm_jit.py"),
                "script import _lldb_txm_jit; _lldb_txm_jit.configure_symbol_lookup(lldb.debugger)",
                "settings set plugin.process.gdb-remote.packet-timeout 300",
                "platform select remote-ios",
                "target create " + lldb_quote(executable),
                f"process connect connect://127.0.0.1:{port}",
                f"process attach --pid {args.pid}",
                "txm_jit_run",
                "",
            ]))
            environment = os.environ.copy()
            environment["WINIOS_JIT_PREPARE"] = "proxy"
            environment["PYTHONPATH"] = str(ROOT / "scripts")
            print("[mac-jit] Attaching LLDB. Select a VM and Start; preparation will batch 128 page writes.", flush=True)
            debugger = subprocess.Popen(["xcrun", "lldb", "-b", "-s", str(commands)], env=environment)
            while debugger.poll() is None:
                if forwarder.poll() is not None:
                    raise RuntimeError(f"USB debugproxy disconnected; see {log_path}")
                if proxy.poll() not in (None, 0):
                    raise RuntimeError("Mac batch proxy aborted; see the protocol error above. "
                                       "Fully close WindowsiOS before retrying.")
                # The proxy normally exits as LLDB disconnects after detach.
                # Let LLDB report its own connection/protocol errors.
                time.sleep(0.1)
            if debugger.returncode:
                raise RuntimeError(f"JIT helper exited with status {debugger.returncode}. Fully close WindowsiOS before retrying.")
    finally:
        stop_child(debugger)
        stop_child(proxy)
        stop_child(forwarder)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n[mac-jit] Stopped. Fully close WindowsiOS before starting a fresh JIT session.", file=sys.stderr)
        sys.exit(130)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"[mac-jit] {error}", file=sys.stderr)
        sys.exit(1)
