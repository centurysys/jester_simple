#!/usr/bin/env python3
"""JS-06: static stream bounds, route-start deadline and RSS observations.

Memory readings are observations; the probe never equates RSS retention with a
live allocation or demands that GC_runOrc return pages to the OS.
"""
import argparse
import json
import os
import socket
import time
from pathlib import Path

HOST = "127.0.0.1"


def open_connection(port, rcvbuf=None):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if rcvbuf:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
    sock.settimeout(4)
    sock.connect((HOST, port))
    return sock


def get(sock, path, method="GET", connection="close"):
    sock.sendall((f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n"
                  f"Connection: {connection}\r\n\r\n").encode("ascii"))


def read_response(sock, *, body=True, expected_byte=None, capture=False):
    header = bytearray()
    while b"\r\n\r\n" not in header:
        packet = sock.recv(4096)
        if not packet:
            raise AssertionError("EOF before headers")
        header.extend(packet)
        assert len(header) < 32768, "oversized response headers"
    prefix, residue = bytes(header).split(b"\r\n\r\n", 1)
    status = prefix.split(b"\r\n", 1)[0]
    fields = {}
    for line in prefix.split(b"\r\n")[1:]:
        key, value = line.split(b":", 1)
        fields[key.decode("ascii").lower()] = value.strip().decode("ascii")
    length = int(fields.get("content-length", 0))
    count = 0
    captured = bytearray()

    def check_chunk(chunk):
        nonlocal count
        if expected_byte is not None and chunk.strip(expected_byte):
            raise AssertionError("unexpected payload content")
        count += len(chunk)
        if capture:
            captured.extend(chunk)

    if body:
        check_chunk(residue)
        while count < length:
            packet = sock.recv(min(65536, length - count))
            if not packet:
                raise AssertionError(f"EOF after {count} of {length} bytes")
            check_chunk(packet)
    elif residue:
        raise AssertionError("body unexpectedly sent for HEAD")
    assert count == (length if body else 0), (count, length)
    if capture:
        return status, fields, count, bytes(captured)
    return status, fields, count


def fds(pid):
    return len(list((Path("/proc") / str(pid) / "fd").iterdir()))


def rss(pid):
    rows = (Path("/proc") / str(pid) / "status").read_text().splitlines()
    return {key: int(value.strip().split()[0])
            for line in rows if line.startswith(("VmRSS:", "VmHWM:"))
            for key, value in (line.split(":", 1),)}


def ping(port):
    with open_connection(port) as sock:
        get(sock, "/ping")
        status, headers, length = read_response(sock)
        assert status == b"HTTP/1.1 200 OK" and length == 4
        assert headers["content-length"] == "4"


def normal_static(port):
    with open_connection(port) as sock:
        get(sock, "/small.bin")
        status, headers, length = read_response(sock, expected_byte=b"a")
        assert status == b"HTTP/1.1 200 OK" and length == 1024 * 1024
        assert headers["content-length"] == str(length)
    with open_connection(port) as sock:
        get(sock, "/small.bin", method="HEAD")
        status, headers, length = read_response(sock, body=False)
        assert status == b"HTTP/1.1 200 OK" and length == 0
        assert headers["content-length"] == str(1024 * 1024)


def native_stream(port):
    with open_connection(port) as sock:
        get(sock, "/native-stream")
        status, headers, length = read_response(sock)
        assert status == b"HTTP/1.1 200 OK" and length == 4
        assert headers["content-length"] == "4"


def slow_static(port, pid):
    baseline = fds(pid)
    with open_connection(port, rcvbuf=4096) as sock:
        get(sock, "/large.bin")
        time.sleep(2.0)  # > 1200ms total stream budget and 400ms send limit
        after = fds(pid)
        assert after <= baseline, (baseline, after)
        ping(port)  # maxConnections=1: stalled stream must relinquish its slot.
        return {"fd_before": baseline, "fd_after": after, "rss": rss(pid)}


def expired_stream(port, pid):
    baseline = fds(pid)
    with open_connection(port) as sock:
        get(sock, "/native-expired")
        # Headers are valid but the declared body must never arrive.
        data = bytearray()
        while b"\r\n\r\n" not in data:
            part = sock.recv(1024)
            assert part, "missing managed streaming response headers"
            data.extend(part)
        prefix, body = bytes(data).split(b"\r\n\r\n", 1)
        assert prefix.startswith(b"HTTP/1.1 200 OK\r\n"), prefix
        assert body == b"", body
        start = time.monotonic()
        sock.settimeout(2.5)
        assert sock.recv(1) == b"", "total stream deadline was not enforced"
        elapsed = time.monotonic() - start
        assert elapsed < 2.5
        ping(port)
        assert fds(pid) <= baseline
        return {"elapsed_after_headers_s": round(elapsed, 3)}


def silent_route(port, pid):
    initial = fds(pid)
    with open_connection(port) as sock:
        get(sock, "/silent")
        # The socket must close before the route's 1700ms sleep completes.
        sock.settimeout(1.2)
        start = time.monotonic()
        assert sock.recv(1) == b"", "silent route unexpectedly sent output"
        elapsed = time.monotonic() - start
        assert elapsed < 1.2, elapsed
        ping(port)
        assert fds(pid) <= initial
        # Allow the timed-out route to run to completion; it must not send.
        time.sleep(1.5)
        return {"closed_after_seconds": round(elapsed, 3), "rss": rss(pid)}


def upgrade(port):
    with open_connection(port) as sock:
        get(sock, "/upgrade", connection="Upgrade")
        header = bytearray()
        while b"\r\n\r\n" not in header:
            part = sock.recv(4096)
            assert part, "socket closed during synthetic Upgrade"
            header.extend(part)
        assert bytes(header).startswith(b"HTTP/1.1 101 Switching Protocols\r\n")
        assert bytes(header).endswith(b"\r\n\r\n")
        assert sock.recv(1) == b"Z", "Upgrade terminated at response-start timeout"
        sock.sendall(b"Q")
        assert sock.recv(1) == b""


def memory_cycles(port, pid):
    measurements = [{"point": "before", "rss": rss(pid)}]
    for i in range(4):
        with open_connection(port) as sock:
            get(sock, "/managed-large")
            status, _, length = read_response(sock, expected_byte=b"m")
            assert status == b"HTTP/1.1 200 OK" and length == 16 * 1024 * 1024
        measurements.append({"point": f"after_{i+1}", "rss": rss(pid)})
    with open_connection(port) as sock:
        get(sock, "/collect")
        status, hdr, length, gc_api = read_response(sock, capture=True)
        assert status == b"HTTP/1.1 200 OK"
    time.sleep(0.25)
    measurements.append({"point": "after_gc_runorc", "api": gc_api.decode("ascii"),
                         "rss": rss(pid)})
    ping(port)
    return measurements


def case(name, func, records):
    try:
        detail = func()
        records.append({"name": name, "result": "PASS", "detail": detail})
        print("PASS", name, flush=True)
    except Exception as exc:
        records.append({"name": name, "result": "FAIL", "detail": repr(exc)})
        print("FAIL", name, str(exc), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--mode", required=True, choices=("debug", "release"))
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    items = []
    start_fds = fds(args.pid)
    case("control_ping", lambda: ping(args.port), items)
    case("normal_static_and_head", lambda: normal_static(args.port), items)
    case("native_managed_stream", lambda: native_stream(args.port), items)
    case("slow_reader_static_slot_reclaim",
         lambda: slow_static(args.port, args.pid), items)
    case("whole_stream_deadline_without_writes",
         lambda: expired_stream(args.port, args.pid), items)
    case("silent_route_start_timeout",
         lambda: silent_route(args.port, args.pid), items)
    case("upgraded_route_exemption", lambda: upgrade(args.port), items)
    case("repeated_managed_send_and_orc_observation",
         lambda: memory_cycles(args.port, args.pid), items)
    case("control_ping_after", lambda: ping(args.port), items)
    def check_fd():
        after = fds(args.pid)
        assert after <= start_fds, (start_fds, after)
        return {"initial": start_fds, "final": after}

    case("fd_reclamation", check_fd, items)
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / f"js06-{args.mode}.json").write_text(json.dumps({
        "mode": args.mode,
        "limits_ms": {"managed_send": 400, "response_start": 350,
                      "stream_total": 1200},
        "tests": items
    }, indent=2), encoding="utf-8")
    if any(row["result"] != "PASS" for row in items):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
