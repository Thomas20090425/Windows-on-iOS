#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Own and relay an LLDB RSP connection, with bounded TXM page preparation.

The upstream endpoint must be a loopback debugserver forwarder. LLDB connects to
this proxy rather than directly to that endpoint. Ordinary packets are relayed
unchanged. After a successful QStartNoAckMode exchange, the LLDB helper can send:

    qWiniosPrepare                         capability query
    qWiniosPrepare:<address>,<length>,4000  hexadecimal, 16 KiB aligned

The preparation request receives OK only after every page's M write receives
exactly OK. Writes are sent in batches of at most 128 before responses are read.
Any transport or response error during preparation closes the whole connection;
residual replies must never become replies to later LLDB commands.

This process owns both of its sockets. It does not inspect or borrow LLDB's
internal connection, and does not connect to a device by itself.

Compression negotiation is deliberately refused with an unsupported response:
the proxy must retain plain RSP framing to inspect requests and synthesize replies.
"""

import argparse
from collections import deque
from dataclasses import dataclass
import errno
import json
import os
from pathlib import Path
import select
import signal
import socket
import sys
import time
from typing import Deque, Optional


PAGE_SIZE = 16 * 1024
MAX_REGION_SIZE = 384 * 1024 * 1024
MAX_ADDRESS = 0x7000000000
BATCH_SIZE = 128
MAX_PACKET_SIZE = 16 * 1024 * 1024
CAPABILITY = b"WiniosPrepare:1;page:4000;batch:80"
_stopping = False


class ProtocolError(RuntimeError):
    """The connection cannot safely continue."""


class StopRequested(RuntimeError):
    """The owner requested a clean proxy shutdown."""


@dataclass
class Token:
    raw: bytes
    kind: str
    payload: bytes = b""
    checksum_valid: bool = True


class PacketParser:
    """Incremental framing; preserve the exact bytes of every relayed token."""

    def __init__(self) -> None:
        self.tokens: Deque[Token] = deque()
        self._raw = bytearray()
        self._payload = bytearray()
        self._checksum = bytearray()
        self._state = "idle"
        self._kind = "packet"

    @property
    def pending(self) -> bool:
        return bool(self.tokens) or self._state != "idle"

    def feed(self, data: bytes) -> None:
        for value in data:
            if self._state == "idle":
                if value in (ord("+"), ord("-"), 3):
                    self.tokens.append(Token(bytes([value]), "control"))
                    continue
                if value not in (ord("$"), ord("%")):
                    raise ProtocolError(f"Unexpected byte 0x{value:02x} outside an RSP packet")
                self._kind = "packet" if value == ord("$") else "notification"
                self._raw = bytearray([value])
                self._payload.clear()
                self._checksum.clear()
                self._state = "payload"
                continue

            self._raw.append(value)
            if len(self._raw) > MAX_PACKET_SIZE:
                raise ProtocolError("RSP packet exceeds the proxy's 16 MiB framing limit")
            if self._state == "payload":
                # Binary quoting turns an embedded '#' into '}\\x03', so the
                # first raw '#' always terminates the wire payload. Match
                # LLDB's framing and leave binary/RLE decoding to each peer.
                if value == ord("#"):
                    self._state = "checksum"
                    continue
                self._payload.append(value)
                continue

            self._checksum.append(value)
            if len(self._checksum) != 2:
                continue
            if any(value not in b"0123456789abcdefABCDEF" for value in self._checksum):
                raise ProtocolError("RSP packet has an invalid checksum field")
            try:
                received = int(self._checksum.decode("ascii"), 16)
            except (ValueError, UnicodeDecodeError) as error:
                raise ProtocolError("RSP packet has an invalid checksum field") from error
            checksum_valid = received == sum(self._payload) & 0xFF
            self.tokens.append(Token(bytes(self._raw), self._kind, bytes(self._payload), checksum_valid))
            self._state = "idle"


def frame(payload: bytes) -> bytes:
    """Frame this proxy's ASCII-only protocol messages."""
    return b"$" + payload + b"#" + f"{sum(payload) & 0xFF:02x}".encode("ascii")


def log(message: str) -> None:
    print(f"[jit-proxy] {message}", file=sys.stderr, flush=True)


def check_stopping() -> None:
    if _stopping:
        raise StopRequested()


def is_stop_reply(payload: bytes) -> bool:
    return (len(payload) >= 3 and payload[:1] in (b"T", b"S")
            and all(value in b"0123456789abcdefABCDEF" for value in payload[1:3]))


def parse_region(payload: bytes) -> tuple:
    fields = payload[len(b"qWiniosPrepare:"):].split(b",")
    if len(fields) != 3 or any(not field or len(field) > 16 for field in fields):
        raise ValueError("Expected address,length,page-size in hexadecimal")
    if any(any(value not in b"0123456789abcdefABCDEF" for value in field) for field in fields):
        raise ValueError("Preparation fields must contain hexadecimal digits only")
    address, length, page_size = (int(field, 16) for field in fields)
    if page_size != PAGE_SIZE:
        raise ValueError("Preparation page size must be 16 KiB")
    if address <= 0 or address % PAGE_SIZE or length <= 0 or length % PAGE_SIZE:
        raise ValueError("Preparation address and positive length must be 16 KiB aligned")
    if length > MAX_REGION_SIZE or address + length > MAX_ADDRESS:
        raise ValueError("Preparation region exceeds the allowed address or 384 MiB size bound")
    return address, length


class Relay:
    def __init__(self, client: socket.socket, upstream: socket.socket, response_timeout: float) -> None:
        self.client = client
        self.upstream = upstream
        self.response_timeout = response_timeout
        self.client_parser = PacketParser()
        self.upstream_parser = PacketParser()
        self.no_ack = False
        self.awaiting_no_ack = False
        self.stopped = False
        self.local_reply_pending: Optional[bytes] = None
        self.pages_prepared = 0
        self.prepare_started: Optional[float] = None
        self.last_progress = 0.0

    def run(self) -> None:
        while True:
            check_stopping()
            readable, _, _ = select.select([self.client, self.upstream], [], [], 0.5)
            # Drain remote packets first, including the no-ack negotiation reply.
            for connection in (self.upstream, self.client):
                if connection not in readable:
                    continue
                data = connection.recv(65536)
                if not data:
                    parser = self.upstream_parser if connection is self.upstream else self.client_parser
                    if parser.pending:
                        raise ProtocolError("Connection closed in the middle of an RSP packet")
                    return
                if connection is self.upstream:
                    self._relay_upstream(data)
                else:
                    self._relay_client(data)

    def _relay_upstream(self, data: bytes) -> None:
        self.upstream_parser.feed(data)
        while self.upstream_parser.tokens:
            token = self.upstream_parser.tokens.popleft()
            self._check_checksum(token)
            if self.awaiting_no_ack and token.kind == "packet":
                self.no_ack = token.payload == b"OK"
                self.awaiting_no_ack = False
                if self.no_ack:
                    # debugserver deliberately sends '#00' after negotiation.
                    # Check framing, but follow RSP's disabled checksum policy.
                    log("Observed successful no-ack negotiation; batched preparation is available")
            if token.kind == "packet" and is_stop_reply(token.payload):
                self.stopped = True
            elif token.kind == "packet" and token.payload[:1] in (b"W", b"X"):
                self.stopped = False
            self.client.sendall(token.raw)

    def _relay_client(self, data: bytes) -> None:
        self.client_parser.feed(data)
        while self.client_parser.tokens:
            token = self.client_parser.tokens.popleft()
            self._check_checksum(token)
            if self.local_reply_pending is not None:
                if token.kind == "control" and token.raw == b"+":
                    self.local_reply_pending = None
                    continue
                if token.kind == "control" and token.raw == b"-":
                    self.client.sendall(self.local_reply_pending)
                    continue
                raise ProtocolError("LLDB sent another command before acknowledging a local response")
            if token.kind == "packet" and token.payload.startswith(b"QEnableCompression"):
                # An empty RSP response means unsupported. Do not let the stub
                # switch to a compressed stream that this proxy cannot frame.
                self._local_response(b"")
            elif token.kind == "packet" and token.payload == b"qWiniosPrepare":
                self._local_response(CAPABILITY)
            elif token.kind == "packet" and token.payload.startswith(b"qWiniosPrepare:"):
                self._prepare_request(token.payload)
            else:
                if token.kind == "packet" and token.payload == b"QStartNoAckMode":
                    self.awaiting_no_ack = True
                if token.kind == "packet" and (
                    token.payload[:1] in (b"c", b"s", b"C", b"S", b"D", b"k", b"R")
                    or token.payload.startswith((b"vRun", b"vAttach"))
                    or (token.payload.startswith(b"vCont;") and token.payload != b"vCont?")
                ):
                    self.stopped = False
                self.upstream.sendall(token.raw)

    def _check_checksum(self, token: Token) -> None:
        # Validate when consuming each token, rather than while framing an
        # entire recv(): negotiation OK and the first no-ack packet can arrive
        # together, and debugserver uses a dummy '#00' checksum in no-ack mode.
        if not self.no_ack and not token.checksum_valid:
            raise ProtocolError("RSP packet checksum mismatch before no-ack negotiation")

    def _local_response(self, payload: bytes) -> None:
        response = frame(payload)
        if not self.no_ack:
            self.client.sendall(b"+")
            self.local_reply_pending = response
        self.client.sendall(response)

    def _prepare_request(self, payload: bytes) -> None:
        if not self.no_ack:
            log("Refused preparation: successful no-ack negotiation was not observed")
            self._local_response(b"E44")
            return
        if not self.stopped:
            log("Refused preparation: debugserver has not reported a stopped target")
            self._local_response(b"E45")
            return
        try:
            address, length = parse_region(payload)
        except ValueError as error:
            log(f"Refused preparation: {error}")
            self._local_response(b"E22")
            return
        # LLDB must wait for this request's reply. A pipelined client command or
        # an unfinished server packet cannot safely share the preparation phase.
        if self.client_parser.pending or self.upstream_parser.pending:
            raise ProtocolError("Preparation requested with other RSP traffic pending")
        page_count = length // PAGE_SIZE
        if self.prepare_started is None:
            self.prepare_started = time.monotonic()
            log(f"Preparing JIT pages with up to {BATCH_SIZE} writes per debugger round trip")
        for first_page in range(0, page_count, BATCH_SIZE):
            check_stopping()
            self._assert_no_pending_traffic()
            count = min(BATCH_SIZE, page_count - first_page)
            commands = b"".join(
                frame(f"M{address + (first_page + index) * PAGE_SIZE:x},1:69".encode("ascii"))
                for index in range(count)
            )
            self.upstream.sendall(commands)
            deadline = time.monotonic() + self.response_timeout
            for _ in range(count):
                reply = self._batch_response(deadline)
                if reply.kind != "packet" or reply.payload != b"OK":
                    detail = repr(reply.payload[:120] if reply.kind != "control" else reply.raw)
                    raise ProtocolError(f"Unexpected {reply.kind} during page preparation: {detail}")
            if self.upstream_parser.pending:
                raise ProtocolError("Extra or incomplete RSP response after a preparation batch")
            self._assert_no_pending_traffic()
            self.pages_prepared += count
            now = time.monotonic()
            if now - self.last_progress >= 2.0:
                elapsed = now - self.prepare_started
                log(f"Prepared {self.pages_prepared:,} JIT pages "
                    f"({self.pages_prepared * PAGE_SIZE // (1024 * 1024)} MiB covered, {elapsed:.1f}s)")
                self.last_progress = now
        self._local_response(b"OK")

    def _assert_no_pending_traffic(self) -> None:
        readable, _, _ = select.select([self.upstream, self.client], [], [], 0)
        if readable:
            peer = "debugserver" if self.upstream in readable else "LLDB"
            raise ProtocolError(f"Unexpected {peer} traffic at a preparation batch boundary")

    def _batch_response(self, deadline: float) -> Token:
        while not self.upstream_parser.tokens:
            check_stopping()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProtocolError("Timed out waiting for preparation write responses")
            readable, _, _ = select.select([self.upstream, self.client], [], [], min(0.5, remaining))
            if self.client in readable:
                data = self.client.recv(65536)
                reason = "LLDB disconnected" if not data else "LLDB sent traffic or an interrupt"
                raise ProtocolError(f"{reason} while a preparation batch was in flight")
            if self.upstream in readable:
                data = self.upstream.recv(65536)
                if not data:
                    raise ProtocolError("Debugserver disconnected during page preparation")
                self.upstream_parser.feed(data)
        return self.upstream_parser.tokens.popleft()


def _port(value: str) -> int:
    number = int(value)
    if not 0 <= number <= 65535:
        raise argparse.ArgumentTypeError("Port must be between 0 and 65535")
    return number


def _request_stop(_signal: int, _frame: object) -> None:
    global _stopping
    _stopping = True


def connect_upstream(port: int, response_timeout: float) -> socket.socket:
    # pymobiledevice3 prints its startup message just before binding the local
    # forwarder. Retry refused connections; a refused socket starts no session.
    deadline = time.monotonic() + 5.0
    while True:
        check_stopping()
        try:
            return socket.create_connection(("127.0.0.1", port),
                                            timeout=min(response_timeout, max(0.1, deadline - time.monotonic())))
        except OSError as error:
            if error.errno != errno.ECONNREFUSED or time.monotonic() >= deadline:
                raise
            time.sleep(0.1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-port", type=_port, required=True,
                        help="Existing debugserver forwarder's IPv4 loopback port")
    parser.add_argument("--local-port", type=_port, default=0,
                        help="IPv4 loopback listen port (default: an ephemeral port)")
    parser.add_argument("--ready-file", type=Path,
                        help="Write JSON containing host and port after the listener is ready")
    parser.add_argument("--response-timeout", type=float, default=60.0,
                        help="Maximum seconds to drain each batch's responses (default: 60)")
    args = parser.parse_args()
    if args.upstream_port == 0:
        parser.error("--upstream-port must be greater than zero")
    if not 0 < args.response_timeout <= 300:
        parser.error("--response-timeout must be greater than zero and at most 300 seconds")
    signal.signal(signal.SIGINT, _request_stop)
    signal.signal(signal.SIGTERM, _request_stop)
    ready_file = args.ready_file
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", args.local_port))
            listener.listen(1)
            listener.settimeout(0.5)
            port = listener.getsockname()[1]
            if port == args.upstream_port:
                raise ProtocolError("Proxy listen port and upstream port must differ")
            if ready_file is not None:
                temporary = ready_file.with_name(f"{ready_file.name}.{os.getpid()}.tmp")
                try:
                    temporary.write_text(json.dumps({"host": "127.0.0.1", "port": port}) + "\n")
                    temporary.replace(ready_file)
                finally:
                    temporary.unlink(missing_ok=True)
            log(f"Listening on 127.0.0.1:{port}; forwarding to 127.0.0.1:{args.upstream_port}")
            while True:
                check_stopping()
                try:
                    client, _address = listener.accept()
                    break
                except socket.timeout:
                    continue
            # Exactly one LLDB connection owns this debugging session.
            with client:
                client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                client.settimeout(args.response_timeout)
                with connect_upstream(args.upstream_port, args.response_timeout) as upstream:
                    upstream.settimeout(args.response_timeout)
                    upstream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    Relay(client, upstream, args.response_timeout).run()
            log("Debugger connection closed")
            return 0
    except StopRequested:
        log("Stopped; debugger connection closed")
        return 0
    except (OSError, ProtocolError) as error:
        log(f"Aborted and closed debugger connection: {error}")
        return 1
    finally:
        if ready_file is not None:
            ready_file.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
