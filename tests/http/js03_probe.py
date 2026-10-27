#!/usr/bin/env python3
"""JS-03 loopback transport-state tests; no actual WebSocket handshake."""
import argparse
import json
import socket
import time
from pathlib import Path


def raw_request(port: int, path: str, *, max_wait: float = 2.0):
    data = bytearray()
    start = time.monotonic()
    closed = False
    with socket.create_connection(("127.0.0.1", port), timeout=1.5) as sock:
        sock.settimeout(0.10)
        upgrade = path.startswith("/upgrade-") and path != "/upgrade-reserved-error"
        connection = "Upgrade" if upgrade else "close"
        sock.sendall((
            f"GET {path} HTTP/1.1\r\nHost: localhost\r\n"
            f"Connection: {connection}\r\n"
            "Upgrade: js03-test\r\n\r\n"
        ).encode("ascii"))
        deadline = start + max_wait
        while time.monotonic() < deadline:
            try:
                chunk = sock.recv(32768)
            except socket.timeout:
                continue
            except ConnectionResetError:
                closed = True
                break
            if not chunk:
                closed = True
                break
            data.extend(chunk)
            if len(data) > 64 * 1024:
                break
    return bytes(data), closed, time.monotonic() - start


def run_case(name, port, tests):
    wire, closed, elapsed = raw_request(port, "/" + name)
    status_count = wire.count(b"HTTP/1.1 ")
    upgrade_count = wire.count(b"HTTP/1.1 101 Switching Protocols")
    if name == "ping":
        ok = wire.startswith(b"HTTP/1.1 200 ") and wire.endswith(b"pong")
    elif name == "reject-before-upgrade":
        ok = wire.startswith(b"HTTP/1.1 400 ") and upgrade_count == 0
    elif name == "upgrade-reserved-error":
        ok = closed and not wire and upgrade_count == 0
    elif name in {"raw-before-upgrade", "managed-before-upgrade"}:
        # A queued raw response may be aborted, so no byte-delivery guarantee.
        ok = closed and upgrade_count == 0 and status_count <= 1
    else:
        ok = (closed and upgrade_count == 1 and status_count == 1
              and b"HTTP/1.1 500" not in wire
              and b"illegal-" not in wire)
    expected_markers = {
        "upgrade-duplicate": b"DUPLICATE_REJECTED",
        "upgrade-raw": b"RAW_REJECTED",
        "upgrade-raw-async": b"RAW_ASYNC_REJECTED",
        "upgrade-raw-headers": b"RAW_HEADERS_REJECTED",
        "upgrade-copy": b"COPY_REJECTED",
    }
    if name in expected_markers:
        ok = ok and expected_markers[name] in wire and b"_ALLOWED" not in wire
    if name == "upgrade-lifetime":
        ok = ok and elapsed >= 0.18
    tests.append({
        "name": name,
        "result": "PASS" if ok else "FAIL",
        "closed": closed,
        "http_status_lines": status_count,
        "http_101_responses": upgrade_count,
        "bytes": len(wire),
        "elapsed_seconds": round(elapsed, 3),
        "prefix": wire[:140].decode("latin-1", errors="replace"),
    })
    print(f"{'PASS' if ok else 'FAIL'} {name}")
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--mode", choices=("debug", "release"), required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    tests = []
    names = (
        "ping", "reject-before-upgrade", "upgrade-lifetime",
        "upgrade-exception", "upgrade-duplicate", "upgrade-managed",
        "upgrade-raw", "upgrade-raw-headers", "upgrade-raw-async", "upgrade-copy",
        "raw-before-upgrade", "managed-before-upgrade",
        "upgrade-reserved-error", "ping",
    )
    for name in names:
        run_case(name, args.port, tests)
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / f"js03-{args.mode}.json").write_text(
        json.dumps({"mode": args.mode, "tests": tests}, indent=2) + "\n",
        encoding="utf-8",
    )
    if any(x["result"] != "PASS" for x in tests):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
