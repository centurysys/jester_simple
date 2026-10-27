#!/usr/bin/env python3
"""JS-12: raw HTTP parser boundary probes. No third-party dependencies."""
from __future__ import annotations

import json
import socket
import sys
import time
from pathlib import Path

HOST = "127.0.0.1"


def request(path: str, headers: list[tuple[str, str]] | None = None) -> bytes:
    fields = [("Host", "localhost")]
    fields.extend(headers or [])
    lines = [f"GET {path} HTTP/1.1"]
    lines.extend(f"{key}: {value}" for key, value in fields)
    return ("\r\n".join(lines) + "\r\n\r\n").encode("ascii")


def response(stream, *, no_body: bool = False) -> tuple[int, bytes]:
    status = stream.readline(16384)
    if not status.startswith(b"HTTP/1.1 "):
        raise AssertionError(f"invalid status line: {status[:100]!r}")
    code = int(status.split(b" ", 2)[1])
    headers = {}
    for _ in range(150):
        line = stream.readline(16384)
        if not line:
            raise AssertionError("EOF in HTTP headers")
        if line == b"\r\n":
            break
        key, sep, value = line.partition(b":")
        if not sep:
            raise AssertionError(f"invalid response header: {line[:80]!r}")
        headers[key.strip().lower()] = value.strip()
    else:
        raise AssertionError("too many response headers")
    count = int(headers.get(b"content-length", b"0"))
    if count > 4096:
        raise AssertionError("unexpected response body size")
    # HEAD responses advertise GET-equivalent Content-Length, but send no body.
    body = b"" if no_body else stream.read(count)
    if not no_body and len(body) != count:
        raise AssertionError(
            f"truncated HTTP response body: expected {count}, got {len(body)}")
    return code, body


def connect(port: int) -> socket.socket:
    sock = socket.create_connection((HOST, port), timeout=3)
    sock.settimeout(3)
    return sock


def single(port: int, data: bytes) -> tuple[int, bytes, bool]:
    with connect(port) as sock:
        file = sock.makefile("rb")
        try:
            sock.sendall(data)
            status, body = response(file)
            sock.settimeout(1.7)
            # EOF proves rejection did not leave an unconsumed oversized line
            # available for the next HTTP parser iteration.
            closed = file.read(1) == b""
            return status, body, closed
        finally:
            file.close()


def sequential(port: int, first: bytes, second: bytes):
    with connect(port) as sock:
        file = sock.makefile("rb")
        try:
            sock.sendall(first)
            a = response(file)
            sock.sendall(second)
            b = response(file)
            return a, b
        finally:
            file.close()


def wait_ready(port: int) -> None:
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        try:
            (code, body), _ = sequential(
                port, request("/ping"), request("/ping", [("Connection", "close")]))
            if code == 200 and body == b"pong":
                return
        except (OSError, AssertionError, ValueError):
            time.sleep(0.05)
    raise RuntimeError("JS-12 server did not start")


def run(out: Path, mode: str, port: int) -> int:
    wait_ready(port)
    rows = []

    def check(name: str, fn) -> None:
        try:
            ok = bool(fn())
            detail = "" if ok else "unexpected HTTP response or connection state"
        except Exception as exc:
            ok = False
            detail = repr(exc)
        rows.append({"name": name, "result": "PASS" if ok else "FAIL", "detail": detail})
        print(f"{'PASS' if ok else 'FAIL'} {mode}: {name} {detail}")

    def uri_reset() -> bool:
        a, b = sequential(port, request("/inspect?x=1"),
                          request("/inspect", [("Connection", "close")]))
        return a == (200, b"/inspect|x=1") and b == (200, b"/inspect|")

    check("uri_query_reset_on_keepalive", uri_reset)

    def uri_reset_reverse() -> bool:
        a, b = sequential(port, request("/inspect"),
                          request("/inspect?y=2", [("Connection", "close")]))
        return a == (200, b"/inspect|") and b == (200, b"/inspect|y=2")

    check("uri_query_replaced_on_keepalive", uri_reset_reverse)

    def line_allowed() -> bool:
        with connect(port) as sock:
            sock.sendall(request("/ping", [("X-Padding", "p" * 8000),
                                            ("Connection", "close")]))
            f = sock.makefile("rb")
            try:
                return response(f) == (200, b"pong")
            finally:
                f.close()

    check("large_but_allowed_header_field", line_allowed)

    def rejected(raw: bytes, expected: int = 431) -> bool:
        # Send a harmless request immediately after the rejected one. It must
        # not be interpreted as a fresh request on this connection.
        status, _, closed = single(port, raw + request("/ping"))
        return status == expected and closed

    check("overlong_request_line_closes", lambda: rejected(
        request("/" + "a" * 8200)))

    def overlong_after_head() -> bool:
        # A HEAD request on this keep-alive connection must not cause the
        # following oversized GET to inherit HttpHead during early rejection.
        with connect(port) as sock:
            file = sock.makefile("rb")
            try:
                sock.sendall(
                    b"HEAD /head-check HTTP/1.1\r\nHost: localhost\r\n\r\n")
                if response(file, no_body=True) != (200, b""):
                    return False
                sock.sendall(request("/" + "a" * 8200) + request("/ping"))
                status, body = response(file)
                sock.settimeout(1.7)
                closed = file.read(1) == b""
                return status == 431 and body.startswith(b"431 ") and closed
            finally:
                file.close()

    check("overlong_request_line_after_head_closes", overlong_after_head)
    check("overlong_header_line_closes", lambda: rejected(
        request("/ping", [("X-Fill", "v" * 8200)])))
    check("aggregate_header_bytes_limit", lambda: rejected(
        request("/ping", [("X-One", "a" * 5500),
                          ("X-Two", "b" * 5500),
                          ("X-Three", "c" * 5500)])))
    check("raw_header_field_count_limit", lambda: rejected(
        request("/ping", [("X-Count", str(i)) for i in range(101)])))

    def duplicate_cookies() -> bool:
        with connect(port) as sock:
            sock.sendall(request("/cookies", [("Cookie", "a=1"),
                                                   ("Cookie", "b=2"),
                                                   ("Connection", "close")]))
            f = sock.makefile("rb")
            try:
                return response(f) == (200, b"1|2")
            finally:
                f.close()

    check("duplicate_cookie_headers_combined", duplicate_cookies)

    def duplicate_connection() -> bool:
        status, body, closed = single(port, request("/headers", [
            ("Connection", "close"), ("Connection", "keep-alive"),
            ("X-Repeat", "first"), ("X-Repeat", "second")]))
        return (status == 200 and
                body == b"close, keep-alive|first|second" and closed)

    check("duplicate_connection_and_custom_preserved", duplicate_connection)

    def connection_kept() -> bool:
        a, b = sequential(port, request("/ping", [
            ("Connection", "keep-alive"), ("Connection", "not-close")]),
            request("/ping", [("Connection", "close")]))
        return a == (200, b"pong") and b == (200, b"pong")

    check("multiple_connection_fields_keepalive", connection_kept)

    for key, values in (
        ("Authorization", ("Bearer one", "Bearer two")),
        ("Proxy-Authorization", ("Basic one", "Basic two")),
        ("Expect", ("something", "else")),
        ("Upgrade", ("alpha", "beta")),
        ("Origin", ("https://one.test", "https://two.test")),
        ("Content-Type", ("text/plain", "application/json")),
    ):
        name = "duplicate_" + key.lower().replace("-", "_") + "_rejected"
        check(name, lambda key=key, values=values: rejected(
            request("/ping", [(key, value) for value in values]), expected=400))

    check("duplicate_content_length_remains_rejected", lambda: rejected(
        request("/ping", [("Content-Length", "0"),
                          ("Content-Length", "0")]), expected=400))
    check("duplicate_forwarded_remains_rejected", lambda: rejected(
        request("/ping", [("Forwarded", "for=192.0.2.1"),
                          ("Forwarded", "for=192.0.2.2")]), expected=400))

    record = {"mode": mode, "passed": sum(r["result"] == "PASS" for r in rows),
              "total": len(rows), "tests": rows}
    (out / f"js12-{mode}.json").write_text(
        json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0 if record["passed"] == record["total"] else 1


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: js12_probe.py OUT MODE PORT")
    raise SystemExit(run(Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])))
