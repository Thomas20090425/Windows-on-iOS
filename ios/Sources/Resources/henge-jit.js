// SPDX-License-Identifier: GPL-2.0-or-later
// The app substitutes the current process's exported handshake address before
// sending this script to StikDebug. A generic debugger is never assumed ready.
const helperAddressText = "__WINIOS_HELPER_ADDRESS__";
const helperToken = 0x574a4954n;
const maximumRegionBytes = 384n << 20n;
let helperAddress;
let tid, x0, x1, x16, pc;
let stopped = false;
let detached = false;

try {
    if (!/^[0-9a-f]+$/i.test(helperAddressText)) {
        throw new Error("Missing current-app JIT handshake address. Request JIT from the updated app.");
    }
    helperAddress = BigInt(`0x${helperAddressText}`);
    if (helperAddress === 0n) throw new Error("Invalid JIT handshake address");
    const pid = get_pid();
    const attached = send_command(`vAttach;${pid.toString(16)}`);
    log(`attach_response = ${attached}`);
    if (!/^[TS][0-9a-f]{2}/i.test(attached)) {
        throw new Error("StikDebug did not stop the requested app process");
    }
    stopped = true;
    setHelperToken(helperToken);

    for (let step = 0; step < 64 && !detached; step++) {
        stopped = false;
        const reply = send_command("c");
        if (!/^T[0-9a-f]{2}/i.test(reply)) {
            throw new Error(`Unexpected process response: ${reply}`);
        }
        stopped = true;
        const threadMatch = /(?:^|;)thread:([0-9a-f]+);/i.exec(reply.slice(3));
        tid = threadMatch ? threadMatch[1] : null;
        const pcMatch = /(?:^|;)20:([0-9a-f]{16});/i.exec(reply.slice(3));
        const commandMatch = /(?:^|;)10:([0-9a-f]{16});/i.exec(reply.slice(3));
        if (!tid || !pcMatch || !commandMatch) {
            throw new Error("Stopped process did not provide the required JIT registers");
        }
        pc = littleEndianHexStringToNumber(pcMatch[1]);
        x16 = littleEndianHexStringToNumber(commandMatch[1]);
        const instruction = send_command(`m${pc.toString(16)},4`);
        if (!/^[0-9a-f]{8}$/i.test(instruction)) {
            throw new Error(`Cannot read stopped instruction at 0x${pc.toString(16)}`);
        }
        const opcode = littleEndianHexToU32(instruction);
        if (((opcode & 0xffe0001f) >>> 0) !== 0xd4200000) {
            throw new Error("Stopped instruction is not a JIT BRK; leaving the process stopped");
        }
        const immediate = (opcode >>> 5) & 0xffff;
        if (immediate === 0x69) {
            // RSP register values are full-width little-endian bytes.
            writeRegister("0", 0xe0000069n);
            writeRegister("20", pc + 4n);
        } else if (immediate === 0xf00d && (x16 === 0n || x16 === 1n)) {
            if (x16 === 0n) {
                setHelperToken(0n);
                writeRegister("20", pc + 4n);
                const response = send_command("D");
                if (response !== "OK") throw new Error(`Detach failed: ${response}`);
                detached = true;
                stopped = false;
            } else {
                const x0Match = /(?:^|;)00:([0-9a-f]{16});/i.exec(reply.slice(3));
                const x1Match = /(?:^|;)01:([0-9a-f]{16});/i.exec(reply.slice(3));
                if (!x0Match || !x1Match) throw new Error("JIT allocation registers unavailable");
                x0 = littleEndianHexStringToNumber(x0Match[1]);
                x1 = littleEndianHexStringToNumber(x1Match[1]);
                if (x1 <= 0n || x1 > maximumRegionBytes || (x1 & 0x3fffn) !== 0n) {
                    throw new Error("Invalid JIT allocation size");
                }
                let address = x0;
                if (address === 0n) {
                    const allocation = send_command(`_M${x1.toString(16)},rx`);
                    if (!/^[0-9a-f]+$/i.test(allocation)) throw new Error(`RX allocation failed: ${allocation}`);
                    address = BigInt(`0x${allocation}`);
                }
                if (address === 0n || address + x1 > 0x7000000000n || (address & 0x3fffn) !== 0n) {
                    throw new Error("JIT allocation is outside the supported RX address range");
                }
                const prepared = prepare_memory_region(address, x1);
                log(`prepare_memory_region = ${prepared}`);
                writeRegister("0", address);
                writeRegister("20", pc + 4n);
            }
        } else {
            // Do not advance PC or continue a guest/host assertion, unknown
            // command or unrelated breakpoint as though it were JIT setup.
            throw new Error(`Unexpected BRK #${immediate.toString(16)} / command ${x16.toString(16)}; process remains stopped`);
        }
    }
    if (!detached) throw new Error("JIT protocol ended without its detach command");
} finally {
    if (stopped && helperAddress !== undefined) {
        try { setHelperToken(0n); }
        catch (error) { log(`Could not clear JIT helper readiness: ${error}`); }
    }
}

function setHelperToken(value) {
    const bytes = numberToLittleEndianHexString(value);
    const response = send_command(`M${helperAddress.toString(16)},8:${bytes}`);
    if (response !== "OK") throw new Error(`JIT helper handshake write failed: ${response}`);
    const observed = send_command(`m${helperAddress.toString(16)},8`);
    if (observed.toLowerCase() !== bytes) throw new Error("JIT helper handshake read-back mismatch");
}

function writeRegister(register, value) {
    const response = send_command(`P${register}=${numberToLittleEndianHexString(value)};thread:${tid};`);
    if (response !== "OK") throw new Error(`Cannot write register ${register}: ${response}`);
}

function littleEndianHexStringToNumber(value) {
    if (!/^[0-9a-f]{16}$/i.test(value)) throw new Error("Invalid 64-bit register value");
    let number = 0n;
    for (let offset = 14; offset >= 0; offset -= 2) {
        number = (number << 8n) | BigInt(parseInt(value.slice(offset, offset + 2), 16));
    }
    return number;
}

function numberToLittleEndianHexString(value) {
    let bytes = "";
    for (let index = 0; index < 8; index++) {
        bytes += Number(value & 0xffn).toString(16).padStart(2, "0");
        value >>= 8n;
    }
    return bytes;
}

function littleEndianHexToU32(value) {
    return parseInt(value.match(/../g).reverse().join(""), 16);
}
