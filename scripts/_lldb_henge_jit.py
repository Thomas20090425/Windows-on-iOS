# SPDX-License-Identifier: GPL-2.0-or-later
"""Exact Henge BRK protocol; loaded only by the explicit Mac JIT launcher."""
import json
import os
from pathlib import Path
import struct
import time
import lldb
import _lldb_txm_jit as txm
from _launch_henge_mac_jit import ROUTINES, image_metadata


def addresses(target, manifest):
    remote = txm.loaded_images(target)
    local_ids = {txm.normalized_uuid(image["uuid"]) for image in manifest["images"]}
    local_names = {Path(image["path"]).name for image in manifest["images"]}
    for image in remote:
        if image["name"] in local_names and image["uuid"] and image["uuid"] not in local_ids:
            raise RuntimeError("Installed Henge UUID differs from the local app; no JIT writes were made")
    for local in manifest["images"]:
        if not all(name in local["symbols"] for name in ROUTINES):
            continue
        for image in remote:
            if image["uuid"] == txm.normalized_uuid(local["uuid"]):
                return {name: image["header"] + value - local["text_vmaddr"]
                        for name, value in local["symbols"].items()}
    return None


def resume_until_stop(debugger, process, timeout):
    debugger.SetAsync(True)
    previous = process.GetStopID()
    error = process.Continue()
    if not error.Success():
        raise RuntimeError("Cannot resume Henge: " + str(error.GetCString()))
    deadline = time.monotonic() + timeout
    event = lldb.SBEvent()
    try:
        while True:
            state = process.GetState()
            if state == lldb.eStateStopped and process.GetStopID() != previous:
                return
            if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed):
                raise RuntimeError(f"Henge left the JIT session in state {state}")
            if time.monotonic() >= deadline:
                process.Stop()
                raise RuntimeError("Henge did not reach the expected JIT/bootstrap stop before timeout")
            debugger.GetListener().WaitForEvent(1, event)
    finally:
        debugger.SetAsync(False)


def run(debugger, command, exe_ctx, result, internal_dict):
    try:
        target = debugger.GetSelectedTarget()
        process = target.GetProcess()
        if not process.IsValid() or process.GetState() != lldb.eStateStopped or process.GetProcessID() <= 0:
            raise RuntimeError("Expected an attached stopped Henge process")
        manifest = json.loads(Path(os.environ["HENGE_JIT_SYMBOLS_JSON"]).read_text())
        if manifest.get("version") != 1:
            raise RuntimeError("Unsupported Henge symbol manifest")
        for image in manifest["images"]:
            if image_metadata(image["path"]) != image:
                raise RuntimeError("Local Henge app changed after symbol preflight")
        txm.preload_local_symbols(target, manifest)
        resolved = addresses(target, manifest)
        if resolved is None:
            breakpoint = target.BreakpointCreateByName("henge_ios_jit_install_trap_handler")
            if not breakpoint.IsValid():
                raise RuntimeError("Cannot set the Henge bootstrap breakpoint")
            try:
                resume_until_stop(debugger, process, 30)
                ours = any(process.GetThreadAtIndex(i).GetStopReason() == lldb.eStopReasonBreakpoint and
                           process.GetThreadAtIndex(i).GetStopReasonDataCount() >= 2 and
                           process.GetThreadAtIndex(i).GetStopReasonDataAtIndex(0) == breakpoint.GetID()
                           for i in range(process.GetNumThreads()))
                if not ours:
                    raise RuntimeError("Henge stopped before its bootstrap; the unrelated stop was not serviced")
                resolved = addresses(target, manifest)
                if resolved is None:
                    raise RuntimeError("Matching Henge JIT image did not load at bootstrap")
            finally:
                target.BreakpointDelete(breakpoint.GetID())
        traps = {resolved["henge_brk_probe"]: (0x69, None),
                 resolved["henge_brk_get_jit_mapping"]: (0xF00D, 1),
                 resolved["henge_brk_jit_detach"]: (0xF00D, 0)}
        for address, (immediate, _) in traps.items():
            error = lldb.SBError()
            data = process.ReadMemory(address, 4, error)
            if not error.Success() or data != struct.pack("<I", 0xD4200000 | immediate << 5):
                raise RuntimeError("UUID-matched Henge trap does not contain its expected BRK opcode")
        print("[henge-jit] Loaded image UUID and all three exact trap instructions verified.", flush=True)
        thread = txm.find_brk_or_stopped_thread(process)
        if not thread or not thread.IsValid():
            raise RuntimeError("Henge has no inspectable stopped thread")
        initial_pc = thread.GetFrameAtIndex(0).FindRegister("pc").GetValueAsUnsigned()
        error = lldb.SBError()
        raw = process.ReadMemory(initial_pc, 4, error) if initial_pc else b""
        initial_brk = error.Success() and len(raw) == 4 and (struct.unpack("<I", raw)[0] & 0xFFE0001F) == 0xD4200000
        if initial_brk and initial_pc not in traps:
            raise RuntimeError("Initial Henge stop is an unrelated BRK; refusing to continue")
        mappings = 0
        for step in range(16):
            if step or not initial_brk:
                resume_until_stop(debugger, process, 90)
            thread = txm.find_brk_or_stopped_thread(process)
            frame = thread.GetFrameAtIndex(0)
            registers = {name: frame.FindRegister(name).GetValueAsUnsigned() for name in ("pc", "x0", "x1", "x16")}
            pc, command_id = registers["pc"], registers["x16"]
            expected = traps.get(pc)
            error = lldb.SBError()
            data = process.ReadMemory(pc, 4, error)
            if (not expected or not error.Success() or data != struct.pack("<I", 0xD4200000 | expected[0] << 5)
                    or expected[1] is not None and expected[1] != command_id):
                raise RuntimeError(f"Unrelated Henge stop at {pc:#x}; refusing to alter its registers")
            if expected[0] == 0x69:
                txm.write_reg(debugger, process, thread, "x0", 0xE0000069)
                txm.write_reg(debugger, process, thread, "pc", pc + 4)
            elif command_id == 1:
                base, size = registers["x0"], registers["x1"]
                if base != 0 or size <= 0 or size % 0x4000 or size > 1536 << 20 or mappings:
                    raise RuntimeError("Refusing an invalid, repeated, or non-fresh Henge JIT allocation")
                response = txm.packet_response(debugger, f"_M{size:x},rx")
                if not re_hex(response):
                    raise RuntimeError("Debugserver refused the Henge executable mapping")
                base = int(response, 16)
                if base <= 0 or base % 0x4000 or base + size > 0x7000000000:
                    raise RuntimeError("Henge executable mapping is outside the validated address range")
                # Keep the Windows helper's 384 MiB operation bound unchanged.
                for offset in range(0, size, 384 << 20):
                    txm.bless_txm_region(debugger, process, base + offset, min(384 << 20, size - offset))
                txm.write_reg(debugger, process, thread, "x0", base)
                txm.write_reg(debugger, process, thread, "pc", pc + 4)
                mappings += 1
            elif command_id == 0:
                if mappings != 1:
                    raise RuntimeError("Henge requested detach before a JIT mapping was prepared")
                txm.write_reg(debugger, process, thread, "pc", pc + 4)
                error = process.Detach()
                if not error.Success():
                    raise RuntimeError("Henge debugger detach failed: " + str(error.GetCString()))
                Path(os.environ["HENGE_JIT_READY_FILE"]).write_text(str(process.GetProcessID()))
                print("[henge-jit] JIT mapping ready; debugger detached.", flush=True)
                return
        raise RuntimeError("Henge exceeded the supported JIT trap count")
    except Exception as error:
        result.SetError(str(error))


def re_hex(value):
    return bool(value) and len(value) <= 16 and all(character in "0123456789abcdefABCDEF" for character in value)


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f _lldb_henge_jit.run henge_jit_run")
