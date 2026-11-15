#!/usr/bin/env python3
"""
Launch WindowsiOS (`me.ammaar.windowsios`) on Ammaar's physical iPhone Duo
(`00008160-000E05D036C0000A`), service the iOS 26/27 TXM BreakpointJIT traps
(`brk #0x69` probe, `brk #0xf00d` RX allocation + 16 KiB page blessing + clean detach),
and let Windows 11 ARM64 run natively at full speed with zero debugger attached.
"""

import argparse
import json
import os
import re
import struct
import subprocess
import sys
import time
import tempfile
from pathlib import Path

# Import Xcode's LLDB Python bindings
lldb_python = subprocess.check_output(["xcrun", "lldb", "-P"], text=True).strip()
if lldb_python not in sys.path:
    sys.path.insert(0, lldb_python)
import lldb  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "work"
DEFAULT_UDID = "00008160-000E05D036C0000A"
DEFAULT_BUNDLE_ID = "me.ammaar.windowsios"


def run_cmd(debugger, cmd: str) -> str:
    res = lldb.SBCommandReturnObject()
    debugger.GetCommandInterpreter().HandleCommand(cmd, res)
    out = (res.GetOutput() or "") + (res.GetError() or "")
    if not res.Succeeded():
        raise RuntimeError(f"LLDB command failed ({cmd}): {out.strip()}")
    return out


def find_stopped_thread(process):
    for i in range(process.GetNumThreads()):
        t = process.GetThreadAtIndex(i)
        sr = t.GetStopReason()
        if sr in (lldb.eStopReasonException, lldb.eStopReasonSignal, lldb.eStopReasonBreakpoint, lldb.eStopReasonPlanComplete):
            return t
    return process.GetSelectedThread()


def bless_txm_region(debugger, process, rx_addr: int, size: int):
    t0 = time.time()
    err = lldb.SBError()
    # First try fast 1 MiB MachVMWrite chunks via SBProcess.WriteMemory (touches every 16 KiB page)
    chunk_size = 1 << 20
    payload = b"\x69" * chunk_size
    wrote = process.WriteMemory(rx_addr, payload[: min(chunk_size, size)], err)
    if err.Success() and wrote == min(chunk_size, size):
        off = wrote
        while off < size:
            cur = min(chunk_size, size - off)
            w = process.WriteMemory(rx_addr + off, payload[:cur], err)
            if not err.Success() or w != cur:
                raise RuntimeError(f"WriteMemory failed at +{off:#x}: {err.GetCString()}")
            off += w
        dt = time.time() - t0
        print(f"[txm-jit] Blessed {size >> 20} MiB RX region at {rx_addr:#x} via bulk WriteMemory in {dt:.2f}s", flush=True)
        return

    print(f"[txm-jit] Bulk WriteMemory returned ({wrote}, {err.GetCString()}); falling back to per-16K-page M packets...", flush=True)
    pages = size // 0x4000
    for idx in range(pages):
        addr = rx_addr + idx * 0x4000
        w = process.WriteMemory(addr, b"\x69", err)
        if not err.Success() or w != 1:
            out = run_cmd(debugger, f"process plugin packet send M{addr:x},1:69")
            if "OK" not in out:
                raise RuntimeError(f"Failed to bless page {addr:#x}: {out}")
        if (idx + 1) % 4096 == 0 or idx + 1 == pages:
            print(f"[txm-jit] Blessed {idx + 1}/{pages} pages ({time.time() - t0:.1f}s)", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default=DEFAULT_UDID)
    ap.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    ap.add_argument("--app", default=os.environ.get("APP_PATH", str(ROOT / "distribution" / "WindowsiOS.app")),
                    help="Local .app matching the installed build, including any Debug dylib")
    args = ap.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9-]+", args.device) or not re.fullmatch(r"[A-Za-z0-9.-]+", args.bundle_id):
        ap.error("Supply an alphanumeric device identifier and bundle identifier")

    WORK.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="duo-jit-symbols-", dir=WORK) as directory:
        symbols_json = Path(directory) / "symbols.json"
        # This reads local Mach-O metadata before launching anything on device.
        subprocess.run([sys.executable, str(ROOT / "scripts" / "jit_symbols.py"),
                        "--app", args.app, "--bundle-id", args.bundle_id,
                        "--output", str(symbols_json)], check=True)
        previous = os.environ.get("WINIOS_JIT_SYMBOLS_JSON")
        os.environ["WINIOS_JIT_SYMBOLS_JSON"] = str(symbols_json)
        try:
            launch(args)
        finally:
            if previous is None:
                os.environ.pop("WINIOS_JIT_SYMBOLS_JSON", None)
            else:
                os.environ["WINIOS_JIT_SYMBOLS_JSON"] = previous


def launch(args):

    WORK.mkdir(parents=True, exist_ok=True)
    launch_json = WORK / "duo_launch.json"
    if launch_json.exists():
        launch_json.unlink()

    print(f"[duo] Launching {args.bundle_id} (--start-stopped) on {args.device}...", flush=True)
    for attempt in range(1, 6):
        r = subprocess.run(
            [
                "xcrun", "devicectl", "device", "process", "launch",
                "--start-stopped",
                "--terminate-existing",
                "--device", args.device,
                "--json-output", str(launch_json),
                args.bundle_id,
            ]
        )
        if r.returncode == 0 and launch_json.exists():
            break
        print(f"[duo] devicectl launch attempt {attempt} returned {r.returncode}; retrying in 2s...", flush=True)
        time.sleep(2)
    else:
        raise RuntimeError("devicectl device process launch failed after 5 attempts")
    info = json.loads(launch_json.read_text())
    pid = info["result"]["process"]["processIdentifier"]
    if type(pid) is not int or pid <= 0:
        raise RuntimeError("Invalid process identifier in devicectl response")
    core_device_id = (
        info.get("result", {}).get("device", {}).get("identifier")
        or args.device
    )
    if not re.fullmatch(r"[A-Za-z0-9-]+", core_device_id):
        raise RuntimeError("Invalid CoreDevice identifier in devicectl response")
    print(f"[duo] Launched stopped PID = {pid} on CoreDevice {core_device_id}; attaching LLDB...", flush=True)

    lldb.SBDebugger.Initialize()
    debugger = lldb.SBDebugger.Create(True)
    debugger.SetAsync(False)

    run_cmd(debugger, f"device select {core_device_id}")
    run_cmd(debugger, f"device process attach -p {pid}")
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    print(f"[duo] Attached to PID {process.GetProcessID()} (state={process.GetState()})", flush=True)

    # Use the same strict handshake/trap policy as the universal device launcher.
    # Keeping a duplicate BRK loop here previously allowed unrelated traps to
    # be skipped and would bypass the helper-readiness check in newer apps.
    from _lldb_txm_jit import txm_jit_cmd
    try:
        txm_jit_cmd(debugger, "", None, None, {})
    except Exception:
        if process.GetState() == lldb.eStateStopped:
            # The standalone Python process is about to exit; explicitly keep
            # the remote process stopped instead of allowing debugger teardown
            # to resume an unhandled exception.
            error = process.Detach(True)
            if not error.Success():
                print(f"[duo] Could not detach while keeping the process stopped: {error.GetCString()}", flush=True)
        raise
    finally:
        lldb.SBDebugger.Destroy(debugger)
        lldb.SBDebugger.Terminate()
    print("[duo] JIT helper completed and detached", flush=True)


if __name__ == "__main__":
    main()
