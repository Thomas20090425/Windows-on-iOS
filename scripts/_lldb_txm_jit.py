"""
LLDB script module imported inside `xcrun lldb` so Xcode's built-in CoreDevice
`device select` + `device process attach` commands are available alongside full
in-process `lldb.SBProcess` speed!
"""

import re
import struct
import time
from pathlib import Path
import lldb

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "work"


def run_cmd(debugger, cmd: str) -> str:
    res = lldb.SBCommandReturnObject()
    debugger.GetCommandInterpreter().HandleCommand(cmd, res)
    out = (res.GetOutput() or "") + (res.GetError() or "")
    if not res.Succeeded():
        raise RuntimeError(f"LLDB command failed ({cmd}): {out.strip()}")
    return out


def write_reg(debugger, process, thread, reg_name: str, val_int: int):
    process.SetSelectedThread(thread)
    frame = thread.GetFrameAtIndex(0)
    val_hex = f"0x{val_int:x}"
    reg = frame.FindRegister(reg_name)
    ok = reg.IsValid() and reg.SetValueFromCString(val_hex)
    if not ok or frame.FindRegister(reg_name).GetValueAsUnsigned() != val_int:
        run_cmd(debugger, f"register write {reg_name} {val_hex}")


def find_brk_or_stopped_thread(process):
    err = lldb.SBError()
    fallback = None
    for i in range(process.GetNumThreads()):
        t = process.GetThreadAtIndex(i)
        sr = t.GetStopReason()
        if sr in (
            lldb.eStopReasonException,
            lldb.eStopReasonSignal,
            lldb.eStopReasonBreakpoint,
            lldb.eStopReasonPlanComplete,
        ):
            if fallback is None:
                fallback = t
            f = t.GetFrameAtIndex(0)
            if f and f.IsValid():
                pc = f.FindRegister("pc").GetValueAsUnsigned()
                if pc != 0:
                    raw = process.ReadMemory(pc, 4, err)
                    if err.Success() and len(raw) == 4:
                        insn = struct.unpack("<I", raw)[0]
                        if (insn & 0xFFE0001F) == 0xD4200000:
                            return t
    return fallback or process.GetSelectedThread()


def bless_txm_region(debugger, process, rx_addr: int, size: int):
    t0 = time.time()
    err = lldb.SBError()
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


HELPER_TOKEN = 0x574A4954


def symbol_load_address(target, symbol_name, symbol_type=lldb.eSymbolTypeAny):
    # Resolve symbols without evaluating expressions in the target process.
    for name in (symbol_name, "_" + symbol_name):
        matches = target.FindSymbols(name, symbol_type)
        for index in range(matches.GetSize()):
            symbol = matches.GetContextAtIndex(index).GetSymbol()
            if not symbol.IsValid():
                continue
            address = symbol.GetStartAddress().GetLoadAddress(target)
            if address != lldb.LLDB_INVALID_ADDRESS and address != 0:
                return address
    raise RuntimeError(f"This app does not expose {symbol_name}. Rebuild/reinstall the current app and matching launcher.")


def helper_token_address(target):
    return symbol_load_address(target, "winios_jit_helper_token", lldb.eSymbolTypeData)


def protocol_traps(target):
    return {
        symbol_load_address(target, "winios_brk_probe_trap"): (0x69, None),
        symbol_load_address(target, "winios_brk_mapping_trap"): (0xF00D, 1),
        symbol_load_address(target, "winios_brk_detach_trap"): (0xF00D, 0),
    }


def write_helper_token(process, address, value):
    if process.GetState() != lldb.eStateStopped:
        raise RuntimeError("JIT helper handshake requires a stopped process")
    payload = struct.pack("<Q", value)
    error = lldb.SBError()
    written = process.WriteMemory(address, payload, error)
    if not error.Success() or written != len(payload):
        raise RuntimeError(f"Cannot write JIT helper handshake: {error.GetCString()}")
    observed = process.ReadMemory(address, len(payload), error)
    if not error.Success() or observed != payload:
        raise RuntimeError("JIT helper handshake read-back did not match")


def txm_jit_cmd(debugger, command, exe_ctx, result, internal_dict):
    debugger.SetAsync(False)
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    if not process or not process.IsValid() or process.GetProcessID() == 0:
        raise RuntimeError("No valid attached process in LLDB")
    print(f"[txm-jit] Attached to PID {process.GetProcessID()} (state={process.GetState()})", flush=True)

    # Wait for initial --start-stopped attach stop to settle with valid thread registers before Continue()
    listener = debugger.GetListener()
    ev = lldb.SBEvent()
    t_wait = time.time()
    while time.time() - t_wait < 10.0:
        if process.GetState() == lldb.eStateStopped and process.GetNumThreads() > 0:
            t0_pc = process.GetThreadAtIndex(0).GetFrameAtIndex(0).FindRegister("pc").GetValueAsUnsigned()
            if t0_pc != 0:
                print(f"[txm-jit] Initial attach settled: state=Stopped, threads={process.GetNumThreads()}, pc={t0_pc:#x}", flush=True)
                break
        if listener.WaitForEvent(1, ev):
            pass
        else:
            time.sleep(0.05)

    token_address = helper_token_address(target)
    traps = protocol_traps(target)
    try:
        write_helper_token(process, token_address, HELPER_TOKEN)
        print("[txm-jit] JIT trap helper armed and read-back verified", flush=True)
        # Importing this command into an Xcode session already stopped at a
        # recognized JIT trap must service that trap before resuming. A fresh
        # --start-stopped launch instead resumes from its initial attach stop.
        initial_thread = find_brk_or_stopped_thread(process)
        initial_pc = initial_thread.GetFrameAtIndex(0).FindRegister("pc").GetValueAsUnsigned()
        error = lldb.SBError()
        initial_raw = process.ReadMemory(initial_pc, 4, error) if initial_pc else b""
        initial_brk = error.Success() and len(initial_raw) == 4 and (struct.unpack("<I", initial_raw)[0] & 0xFFE0001F) == 0xD4200000
        if initial_brk and initial_pc not in traps:
            raise RuntimeError(f"Initial stop is an unrelated BRK at {initial_pc:#x}; refusing to continue")
        service_current_stop = initial_brk and initial_pc in traps
        detached = False
        for step in range(1, 64):
            if step != 1 or not service_current_stop:
                process.Continue()
            state = process.GetState()
            if state != lldb.eStateStopped:
                raise RuntimeError(f"Process entered unexpected state {state} at step {step}")

            thread = find_brk_or_stopped_thread(process)
            process.SetSelectedThread(thread)
            frame = thread.GetFrameAtIndex(0)
            pc = frame.FindRegister("pc").GetValueAsUnsigned()
            x0 = frame.FindRegister("x0").GetValueAsUnsigned()
            x1 = frame.FindRegister("x1").GetValueAsUnsigned()
            x16 = frame.FindRegister("x16").GetValueAsUnsigned()

            err = lldb.SBError()
            raw = process.ReadMemory(pc, 4, err) if pc != 0 else b""
            if not err.Success() or len(raw) != 4:
                desc = thread.GetStopDescription(128)
                raise RuntimeError(f"Cannot inspect stopped instruction at {pc:#x} ({desc}); refusing to continue")

            insn = struct.unpack("<I", raw)[0]
            if (insn & 0xFFE0001F) != 0xD4200000:
                desc = thread.GetStopDescription(128)
                raise RuntimeError(f"Unexpected stop at {pc:#x}, instruction {insn:#010x} ({desc}); refusing to continue")

            imm = (insn >> 5) & 0xFFFF
            expected = traps.get(pc)
            if expected is None or imm != expected[0] or (expected[1] is not None and x16 != expected[1]):
                raise RuntimeError(f"Stop at {pc:#x} is not an exact supported JIT trap/command; leaving it stopped")
            print(f"[txm-jit] Stop #{step}: BRK #{imm:#x} tid={thread.GetIndexID()} at pc={pc:#x} (x0={x0:#x}, x1={x1:#x}, x16={x16:#x})", flush=True)

            if imm == 0x69:
                write_reg(debugger, process, thread, "x0", 0xE0000069)
                write_reg(debugger, process, thread, "pc", pc + 4)
                print("[txm-jit] Answered probe BRK #0x69 -> x0 = 0xE0000069", flush=True)
            elif imm == 0xF00D:
                if x16 == 1:
                    rx_addr = x0
                    if rx_addr == 0:
                        pkt_out = run_cmd(debugger, f"process plugin packet send _M{x1:x},rx")
                        m = re.search(r"response:\s*([0-9a-fA-F]+)", pkt_out)
                        if not m:
                            raise RuntimeError(f"Unexpected _M packet response: {pkt_out}")
                        rx_addr = int(m.group(1), 16)
                        print(f"[txm-jit] Allocated {x1 >> 20} MiB RX region at {rx_addr:#x}", flush=True)
                    bless_txm_region(debugger, process, rx_addr, x1)
                    write_reg(debugger, process, thread, "x0", rx_addr)
                    write_reg(debugger, process, thread, "pc", pc + 4)
                elif x16 == 0:
                    write_reg(debugger, process, thread, "pc", pc + 4)
                    print("[txm-jit] Servicing CMD_DETACH -> detaching LLDB cleanly!", flush=True)
                    write_helper_token(process, token_address, 0)
                    err = process.Detach()
                    if not err.Success():
                        raise RuntimeError(f"Detach failed: {err.GetCString()}")
                    detached = True
                    break
                else:
                    raise RuntimeError(f"Unknown JIT command {x16:#x}; leaving the process stopped")
            else:
                raise RuntimeError(f"Unexpected BRK #{imm:#x}; leaving the process stopped")

        if not detached:
            raise RuntimeError("Exited loop without seeing CMD_DETACH")
        print("[txm-jit] SUCCESS: TXM JIT + Ledger-Exempt Guest RAM active and debugger detached!", flush=True)
    finally:
        if process.GetState() == lldb.eStateStopped:
            try:
                write_helper_token(process, token_address, 0)
            except Exception as error:
                print(f"[txm-jit] Could not clear helper readiness: {error}", flush=True)


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f _lldb_txm_jit.txm_jit_cmd txm_jit_run")
