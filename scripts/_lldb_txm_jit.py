"""
LLDB script module imported inside `xcrun lldb` so Xcode's built-in CoreDevice
`device select` + `device process attach` commands are available alongside full
in-process `lldb.SBProcess` speed!
"""

import json
import os
import re
import struct
import sys
import time
from pathlib import Path
import lldb

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "work"
if str(ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(ROOT / "scripts"))


def run_cmd(debugger, cmd: str) -> str:
    res = lldb.SBCommandReturnObject()
    debugger.GetCommandInterpreter().HandleCommand(cmd, res)
    out = (res.GetOutput() or "") + (res.GetError() or "")
    if not res.Succeeded():
        raise RuntimeError(f"LLDB command failed ({cmd}): {out.strip()}")
    return out


def configure_symbol_lookup(debugger):
    # Only this helper's debugger session is affected. Protocol addresses come
    # from UUID-matched local Mach-O files; Spotlight/network symbol discovery
    # must not hold up JIT setup. Never change the user's .lldbinit or defaults.
    run_cmd(debugger, "settings set symbols.enable-external-lookup false")
    run_cmd(debugger, "settings set symbols.enable-background-lookup false")
    optional = lldb.SBCommandReturnObject()
    debugger.GetCommandInterpreter().HandleCommand("settings set symbols.auto-download off", optional)
    if not optional.Succeeded():
        print("[txm-jit] This LLDB lacks symbols.auto-download; external/background lookup is disabled", flush=True)


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
    page_size = 0x4000
    if (rx_addr <= 0 or rx_addr % page_size or size <= 0 or size % page_size or
            size > (384 << 20) or rx_addr + size > 0x7000000000):
        raise RuntimeError("Invalid JIT region; refusing debugger memory preparation")
    if process.GetState() != lldb.eStateStopped:
        raise RuntimeError("JIT memory preparation requires a stopped target process")
    mode = os.environ.get("WINIOS_JIT_PREPARE", "auto")
    if mode == "proxy":
        return bless_txm_proxy(debugger, rx_addr, size, page_size)
    if mode not in ("auto", "pages", "bulk"):
        raise RuntimeError("WINIOS_JIT_PREPARE must be auto (default), pages, bulk, or proxy")
    if mode in ("auto", "bulk"):
        try:
            # This is the encoded remote packet limit, not the Python buffer
            # size. Normal M writes encode each payload byte as two hex digits.
            # Without this override some stubs leave LLDB at 256-byte writes.
            run_cmd(debugger, "process plugin packet xfer-size 131072")
        except RuntimeError as error:
            if mode == "bulk":
                raise
            print(f"[txm-jit] Cannot tune bulk transfer size; using page writes: {error}", flush=True)
            mode = "pages"
    if mode == "auto":
        mode = select_txm_prepare_method(debugger, process, rx_addr, size, page_size)
    if mode == "bulk":
        return bless_txm_bulk(debugger, process, rx_addr, size)
    return bless_txm_pages(debugger, rx_addr, size, page_size)


def packet_response(debugger, packet: str) -> str:
    output = run_cmd(debugger, f"process plugin packet send {packet}")
    replies = re.findall(r"^[ \t]*response:[ \t]*([^\r\n]*)", output, re.MULTILINE)
    if len(replies) != 1:
        raise RuntimeError(f"Debugger packet did not return exactly one response: {output.strip()}")
    return replies[0].strip()


def prepare_txm_page(debugger, address: int):
    reply = packet_response(debugger, f"M{address:x},1:69")
    if reply != "OK":
        raise RuntimeError(f"JIT page at {address:#x} was not acknowledged: {reply!r}. "
                           "The app remains stopped; no pages are skipped.")


def write_txm_bulk(process, address: int, payload: bytes):
    error = lldb.SBError()
    written = process.WriteMemory(address, payload, error)
    if not error.Success() or written != len(payload):
        raise RuntimeError(f"Bulk JIT write at {address:#x} wrote {written}/{len(payload)} bytes: "
                           f"{error.GetCString() or 'incomplete write'}")


def select_txm_prepare_method(debugger, process, rx_addr: int, size: int, page_size: int) -> str:
    # Calibrate on this connection rather than assuming that fewer payload
    # bytes beat fewer round trips. Samples stay inside the fresh RX region;
    # the selected method then prepares the entire region, including samples.
    bulk_size = min(1 << 20, size)
    sample_pages = min(8, size // page_size)
    print(f"[txm-jit] Comparing tuned bulk ({bulk_size >> 10} KiB) with "
          f"{sample_pages} page writes on this debugger connection. The app stays paused.", flush=True)
    started = time.monotonic()
    try:
        write_txm_bulk(process, rx_addr, b"\x69" * bulk_size)
    except RuntimeError as error:
        print(f"[txm-jit] Bulk sample failed; preparing every page with acknowledged writes: {error}", flush=True)
        return "pages"
    bulk_seconds = max(time.monotonic() - started, 0.000001)
    started = time.monotonic()
    for index in range(sample_pages):
        prepare_txm_page(debugger, rx_addr + index * page_size)
    page_seconds = max(time.monotonic() - started, 0.000001)
    bulk_rate = bulk_size / bulk_seconds
    page_rate = sample_pages * page_size / page_seconds
    # Small timing differences are noisy; bulk must have a clear advantage.
    selected = "bulk" if bulk_rate > page_rate * 1.10 else "pages"
    rate = bulk_rate if selected == "bulk" else page_rate
    print(f"[txm-jit] Observed coverage: tuned bulk {bulk_rate / (1 << 20):.2f} MiB/s, "
          f"page writes {page_rate / (1 << 20):.2f} MiB/s; selecting {selected}. "
          f"Estimated preparation time {size / rate:.0f}s (connection speed can vary).", flush=True)
    return selected


def bless_txm_proxy(debugger, rx_addr: int, size: int, page_size: int):
    capability = packet_response(debugger, "qWiniosPrepare")
    if capability != "WiniosPrepare:1;page:4000;batch:80":
        raise RuntimeError(f"JIT batching proxy is not ready: {capability!r}. "
                           "Use the Mac proxy launcher; the app remains stopped.")
    print(f"[txm-jit] Preparing {size // page_size:,} JIT pages through the Mac batching proxy "
          "(128 page writes per batch). The app stays paused.", flush=True)
    started = time.monotonic()
    offset = 0
    while offset < size:
        # Each request is bounded to 512 pages / four batches so progress and
        # failures are reported without waiting for the full 384 MiB region.
        chunk = min(8 << 20, size - offset)
        reply = packet_response(debugger, f"qWiniosPrepare:{rx_addr + offset:x},{chunk:x},{page_size:x}")
        if reply != "OK":
            raise RuntimeError(f"JIT batching proxy failed at +{offset:#x}: {reply!r}. "
                               "The app remains stopped; no pages are skipped.")
        offset += chunk
        elapsed = time.monotonic() - started
        remaining = elapsed * (size - offset) / offset
        print(f"[txm-jit] Prepared JIT pages: {offset // page_size:,}/{size // page_size:,} "
              f"({100 * offset / size:.0f}%, {offset >> 20}/{size >> 20} MiB covered, "
              f"{elapsed:.1f}s, observed ETA {remaining:.0f}s)", flush=True)
    print(f"[txm-jit] All {size // page_size:,} JIT pages acknowledged in "
          f"{time.monotonic() - started:.1f}s. The app's RX execution check still runs before the VM starts.", flush=True)


def bless_txm_pages(debugger, rx_addr: int, size: int, page_size: int):
    pages = size // page_size
    started = last_report = time.monotonic()
    print(f"[txm-jit] Preparing {pages:,} JIT pages covering {size >> 20} MiB "
          f"with {pages:,} bytes of payload (one byte per 16 KiB page).", flush=True)
    print("[txm-jit] Using serial debugger packets; completion depends on observed round-trip latency.", flush=True)
    for index in range(pages):
        address = rx_addr + index * page_size
        prepare_txm_page(debugger, address)
        done = index + 1
        now = time.monotonic()
        if done == 1 or done == pages or done % 256 == 0 or now - last_report >= 2:
            elapsed = now - started
            eta = ""
            if done >= 128 and elapsed > 0:
                remaining = elapsed * (pages - done) / done
                eta = f", observed ETA {remaining:.0f}s" if remaining < 120 else f", observed ETA {remaining / 60:.1f}min"
            print(f"[txm-jit] Prepared JIT pages: {done:,}/{pages:,} ({100 * done / pages:.0f}%, "
                  f"{done * page_size / (1 << 20):.0f}/{size >> 20} MiB covered, {elapsed:.1f}s{eta})", flush=True)
            last_report = now
    print(f"[txm-jit] All {pages:,} JIT pages acknowledged in {time.monotonic() - started:.1f}s. "
          "The app's RX execution check still runs before the VM starts.", flush=True)


def bless_txm_bulk(debugger, process, rx_addr: int, size: int):
    t0 = time.monotonic()
    last_report = t0
    print(f"[txm-jit] Preparing JIT memory: 0/{size >> 20} MiB. The app stays paused during this transfer.", flush=True)

    def progress(done, force=False):
        nonlocal last_report
        now = time.monotonic()
        if force or done == size or done % (16 << 20) == 0 or now - last_report >= 2:
            print(f"[txm-jit] Preparing JIT memory: {done / (1 << 20):.0f}/{size >> 20} MiB "
                  f"({100 * done / size:.0f}%, {now - t0:.1f}s)", flush=True)
            last_report = now

    chunk_size = 1 << 20
    payload = b"\x69" * chunk_size
    off = 0
    while off < size:
        cur = min(chunk_size, size - off)
        write_txm_bulk(process, rx_addr + off, payload[:cur])
        off += cur
        progress(off, force=off == cur)
    dt = time.monotonic() - t0
    print(f"[txm-jit] Prepared all {size >> 20} MiB RX region at {rx_addr:#x} via tuned bulk WriteMemory "
          f"in {dt:.2f}s. The app's RX execution check still runs before the VM starts.", flush=True)


HELPER_TOKEN = 0x574A4954


class JITImageNotLoaded(RuntimeError):
    pass


def normalized_uuid(value):
    return (value or "").replace("-", "").upper()


def symbol_manifest():
    path = os.environ.get("WINIOS_JIT_SYMBOLS_JSON")
    if not path:
        return None
    from jit_symbols import read_image
    manifest = json.loads(Path(path).read_text())
    if manifest.get("version") != 1:
        raise RuntimeError("Unsupported local JIT symbol manifest; rerun the updated launcher")
    for image in manifest["images"]:
        actual = read_image(image["path"])
        if actual != image:
            raise RuntimeError("Local app changed after symbol preflight. Rerun the launcher with the installed app's APP_PATH.")
    for image_uuid, symbol_file in manifest.get("symbol_files", {}).items():
        if normalized_uuid(read_image(symbol_file, include_symbols=False)["uuid"]) != normalized_uuid(image_uuid):
            raise RuntimeError("Local dSYM no longer matches the app. Rerun the launcher after rebuilding.")
    return manifest


def preload_local_symbols(target, manifest):
    for image in manifest["images"]:
        symbol_file = manifest.get("symbol_files", {}).get(image["uuid"])
        if symbol_file:
            module = target.AddModule(image["path"], "arm64-apple-ios", image["uuid"], symbol_file)
        else:
            module = target.AddModule(image["path"], "arm64-apple-ios", image["uuid"])
        if not module.IsValid():
            raise RuntimeError(f"LLDB could not load local image metadata: {image['path']}")


def loaded_images(target):
    images = []
    for index in range(target.GetNumModules()):
        module = target.GetModuleAtIndex(index)
        address = module.GetObjectFileHeaderAddress().GetLoadAddress(target)
        if address == lldb.LLDB_INVALID_ADDRESS:
            section = module.FindSection("__TEXT")
            address = section.GetLoadAddress(target) if section.IsValid() else lldb.LLDB_INVALID_ADDRESS
        if address in (0, lldb.LLDB_INVALID_ADDRESS):
            continue
        images.append({"uuid": normalized_uuid(module.GetUUIDString()), "header": address,
                       "name": module.GetFileSpec().GetFilename() or ""})
    return images


def manifest_addresses(target, manifest):
    from jit_symbols import REQUIRED
    remote = loaded_images(target)
    local_ids = {normalized_uuid(image["uuid"]) for image in manifest["images"]}
    names = {Path(image["path"]).name for image in manifest["images"]}
    for image in remote:
        if image["name"] in names and image["uuid"] and image["uuid"] not in local_ids:
            raise RuntimeError(
                f"App UUID mismatch: device {image['name']} has UUID {image['uuid']}, which is not in {manifest['app']}. "
                "Set APP_PATH to the exact .app installed by Xcode, or install the local development app before launching. "
                "No JIT addresses have been written."
            )
    for local in manifest["images"]:
        if not all(name in local["symbols"] for name in REQUIRED):
            continue
        for image in remote:
            if image["uuid"] == normalized_uuid(local["uuid"]):
                # UUID is the identity boundary. Each image has its own slide:
                # Debug dylibs start at zero; Release executables usually don't.
                return {name: image["header"] + value - local["text_vmaddr"]
                        for name, value in local["symbols"].items()}
    raise JITImageNotLoaded("The matching app JIT image has not been loaded by dyld yet")


def wait_for_bootstrap(debugger, target, process, manifest):
    # Load metadata only. Do not assign guessed runtime addresses to modules.
    preload_local_symbols(target, manifest)
    breakpoint = target.BreakpointCreateByName("winios_jit_install_trap_handler")
    if not breakpoint.IsValid():
        raise RuntimeError("Cannot prepare the app bootstrap breakpoint")
    identifier = breakpoint.GetID()
    print("[txm-jit] Waiting for the app's Debug JIT image to load at bootstrap", flush=True)
    try:
        # An initial stopped launch can precede Debug dylib loading. Bound this
        # bootstrap wait so a mismatched/old app cannot leave the helper hanging.
        debugger.SetAsync(True)
        initial_stop = process.GetStopID()
        error = process.Continue()
        if not error.Success():
            raise RuntimeError(f"Cannot resume app bootstrap: {error.GetCString()}")
        deadline = time.monotonic() + 30.0
        listener, event = debugger.GetListener(), lldb.SBEvent()
        while True:
            state = process.GetState()
            if state == lldb.eStateStopped and process.GetStopID() != initial_stop:
                break
            if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed):
                raise RuntimeError(f"App left bootstrap in state {state}; no JIT addresses were written")
            if time.monotonic() >= deadline:
                stopped = process.Stop()
                if not stopped.Success() or process.GetState() != lldb.eStateStopped:
                    raise RuntimeError(f"App bootstrap timed out and could not be stopped: {stopped.GetCString()}. No JIT addresses were written.")
                raise RuntimeError("Timed out before the app JIT image loaded. Check APP_PATH against the installed app; no JIT addresses were written.")
            listener.WaitForEvent(1, event)
        if process.GetState() != lldb.eStateStopped:
            raise RuntimeError(f"App left bootstrap in state {process.GetState()}; no JIT addresses were written")
        our_stop = any(
            process.GetThreadAtIndex(index).GetStopReason() == lldb.eStopReasonBreakpoint and
            process.GetThreadAtIndex(index).GetStopReasonDataCount() >= 2 and
            process.GetThreadAtIndex(index).GetStopReasonDataAtIndex(0) == identifier
            for index in range(process.GetNumThreads())
        )
        if not our_stop:
            raise RuntimeError("App stopped before the JIT bootstrap breakpoint; leaving the unrelated stop untouched")
        return manifest_addresses(target, manifest)
    finally:
        debugger.SetAsync(False)
        if process.GetState() not in (lldb.eStateRunning, lldb.eStateStepping, lldb.eStateLaunching):
            target.BreakpointDelete(identifier)


def resolve_jit_addresses(debugger, target, process):
    manifest = symbol_manifest()
    if manifest:
        preload_local_symbols(target, manifest)
        try:
            addresses = manifest_addresses(target, manifest)
        except JITImageNotLoaded:
            addresses = wait_for_bootstrap(debugger, target, process, manifest)
        # Validate relocated code before any handshake write. An incorrect
        # symbol type, slide or stale local build must never become an address.
        expected = {"winios_brk_probe_trap": 0x69,
                    "winios_brk_mapping_trap": 0xF00D, "winios_brk_detach_trap": 0xF00D}
        for name, immediate in expected.items():
            error = lldb.SBError()
            observed = process.ReadMemory(addresses[name], 4, error)
            wanted = struct.pack("<I", 0xD4200000 | (immediate << 5))
            if not error.Success() or observed != wanted:
                raise RuntimeError(f"Relocated {name} does not contain its expected instruction; refusing to arm JIT")
        return addresses
    # Xcode console users may already have complete local symbols loaded.
    # The universal launcher always supplies the UUID-checked manifest.
    from jit_symbols import REQUIRED
    return {name: symbol_load_address(target, name) for name in REQUIRED}


def symbol_load_address(target, symbol_name, symbol_type=lldb.eSymbolTypeAny):
    # Resolve symbols without evaluating expressions in the target process.
    for kind in dict.fromkeys((symbol_type, lldb.eSymbolTypeAny)):
        for name in (symbol_name, "_" + symbol_name):
            matches = target.FindSymbols(name, kind)
            for index in range(matches.GetSize()):
                symbol = matches.GetContextAtIndex(index).GetSymbol()
                if not symbol.IsValid():
                    continue
                address = symbol.GetStartAddress().GetLoadAddress(target)
                if address != lldb.LLDB_INVALID_ADDRESS and address != 0:
                    return address
    raise RuntimeError(f"LLDB has no loaded symbol for {symbol_name}. Use launch_on_device.sh with APP_PATH set to the matching local .app.")


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


def run_txm_jit(debugger, command, exe_ctx, result, internal_dict):
    configure_symbol_lookup(debugger)
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

    addresses = resolve_jit_addresses(debugger, target, process)
    token_address = addresses["winios_jit_helper_token"]
    traps = {addresses["winios_brk_probe_trap"]: (0x69, None),
             addresses["winios_brk_mapping_trap"]: (0xF00D, 1),
             addresses["winios_brk_detach_trap"]: (0xF00D, 0)}
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


def txm_jit_cmd(debugger, command, exe_ctx, result, internal_dict):
    try:
        return run_txm_jit(debugger, command, exe_ctx, result, internal_dict)
    except Exception as error:
        if result is None:  # Standalone launcher owns its explicit cleanup.
            raise
        result.SetError(str(error))


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f _lldb_txm_jit.txm_jit_cmd txm_jit_run")
