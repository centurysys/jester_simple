#!/usr/bin/env python3
"""JS-01: check HEAD bytes on the wire and keep-alive synchronization.

Runs only against tests/http/js01_server.nim on 127.0.0.1:5511.
"""
from __future__ import annotations

import argparse
import json
import socket
from datetime import datetime, timezone
from pathlib import Path

HOST = "127.0.0.1"
PORT = 5511
MAX_RESPONSE = 128 * 1024


def connect() -> socket.socket:
    sock = socket.create_connection((HOST, PORT), timeout=5)
    sock.settimeout(5)
    return sock


def request_bytes(method: str, path: str, connection: str = "close") -> bytes:
    with connect() as sock:
        sock.sendall(
            f"{method} {path} HTTP/1.1\r\n"
            f"Host: localhost\r\nConnection: {connection}\r\n\r\n".encode("ascii")
        )
        data = bytearray()
        while True:
            chunk = sock.recv(8192)
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > MAX_RESPONSE:
                raise AssertionError("Response exceeded the test size bound")
        return bytes(data)


def parse_response(data: bytes) -> tuple[int, dict[str, str], bytes]:
    header, separator, body = data.partition(b"\r\n\r\n")
    if not separator:
        raise AssertionError("Missing header terminator")
    lines = header.split(b"\r\n")
    if not lines[0].startswith(b"HTTP/1.1 "):
        raise AssertionError(f"Invalid status line: {lines[0][:80]!r}")
    status = int(lines[0].split(b" ", 2)[1])
    fields: dict[str, str] = {}
    for line in lines[1:]:
        key, sep, value = line.partition(b":")
        if not sep:
            raise AssertionError(f"Malformed header: {line[:80]!r}")
        name = key.decode("ascii").lower()
        if name in fields:
            raise AssertionError(f"Unexpected duplicate field: {name}")
        fields[name] = value.strip().decode("latin-1")
    return status, fields, body


def read_headers(sock: socket.socket) -> tuple[int, dict[str, str], bytes]:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(8192)
        if not chunk:
            raise AssertionError("EOF while waiting for response headers")
        data.extend(chunk)
        if len(data) > 32768:
            raise AssertionError("Headers exceeded 32 KiB")
    return parse_response(bytes(data))


def check_equivalent(path: str, expected_status: int,
                     expected_body: bytes | None = None) -> dict[str, object]:
    get_status, get_fields, get_body = parse_response(request_bytes("GET", path))
    head_status, head_fields, head_body = parse_response(request_bytes("HEAD", path))

    assert get_status == expected_status, (path, "GET", get_status)
    assert head_status == get_status, (path, "HEAD", head_status)
    if expected_body is not None:
        assert get_body == expected_body, (path, "GET body", get_body)
    assert get_fields.get("content-length") == str(len(get_body)), (
        path, "GET Content-Length", get_fields
    )
    assert head_fields.get("content-length") == str(len(get_body)), (
        path, "HEAD Content-Length", head_fields
    )
    assert head_fields.get("content-type") == get_fields.get("content-type"), (
        path, "Content-Type mismatch"
    )
    assert head_body == b"", (path, "unexpected HEAD body", head_body[:100])
    return {"get_body_bytes": len(get_body), "head_body_bytes": len(head_body),
            "status": head_status}


def check_keepalive() -> dict[str, object]:
    # Two HEAD requests and then a GET on one HTTP/1.1 connection. A leaked
    # HEAD body will either appear before the next response or contaminate it.
    with connect() as sock:
        for path, status in (("/managed", 200), ("/generated404", 404)):
            sock.sendall(f"HEAD {path} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
            code, fields, extra = read_headers(sock)
            assert code == status, (path, code)
            assert "content-length" in fields, (path, fields)
            assert extra == b"", (path, "HEAD body after headers", extra[:100])

        sock.sendall(b"GET /ping HTTP/1.1\r\nHost: localhost\r\n"
                     b"Connection: close\r\n\r\n")
        data = bytearray()
        while True:
            chunk = sock.recv(8192)
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > MAX_RESPONSE:
                raise AssertionError("Oversized keep-alive response")
        code, headers, body = parse_response(bytes(data))
        assert code == 200 and body == b"pong", (code, body[:100])
        assert headers.get("content-length") == "4", headers
    return {"head_requests": 2, "get_response": 200}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--mode", choices=("debug", "release"), required=True)
    parser.add_argument("--matcher", choices=("single", "multi", "async"), required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    cases: list[dict[str, object]] = []

    def check(name: str, fn) -> None:
        try:
            details = fn()
            cases.append({"name": name, "result": "PASS", "details": details})
            print(f"PASS {args.mode}/{args.matcher}: {name}")
        except Exception as exc:
            cases.append({"name": name, "result": "FAIL", "details": repr(exc)})
            print(f"FAIL {args.mode}/{args.matcher}: {name}: {exc}")

    check("head_200", lambda: check_equivalent(
        "/managed", 200, b"js01-managed-response"))
    check("head_explicit_length", lambda: check_equivalent(
        "/explicit", 200, b"js01-explicit-length"))
    check("head_empty", lambda: check_equivalent("/empty", 200, b""))
    check("head_explicit_404", lambda: check_equivalent(
        "/error", 404, b"js01-explicit-error"))
    check("head_generated_404", lambda: check_equivalent("/generated404", 404))
    check("head_generated_500", lambda: check_equivalent("/invalid-response", 500))
    check("head_keepalive_get", check_keepalive)
    def check_ping() -> dict[str, object]:
        status, headers, body = parse_response(request_bytes("GET", "/ping"))
        assert status == 200 and body == b"pong", (status, body[:100])
        assert headers.get("content-length") == "4", headers
        return {"status": status, "body_bytes": len(body)}

    check("get_ping_control", check_ping)

    output = args.out / f"js01-{args.matcher}-{args.mode}.json"
    record = {"captured_utc": datetime.now(timezone.utc).isoformat(),
              "mode": args.mode, "matcher": args.matcher, "tests": cases}
    output.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return 0 if all(c["result"] == "PASS" for c in cases) else 1


if __name__ == "__main__":
    raise SystemExit(main())
