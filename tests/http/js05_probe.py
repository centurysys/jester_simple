#!/usr/bin/env python3
"""JS-05: inspect HTTP framing, timeout close and upgraded socket lifetime."""
import argparse
import json
import os
import socket
import time
from pathlib import Path

HOST = "127.0.0.1"


def connect(port, rcvbuf=None):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if rcvbuf is not None:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
    sock.settimeout(4)
    sock.connect((HOST, port))
    return sock


def request(sock, path, method="GET", protocol="HTTP/1.1", connection="close"):
    sock.sendall((f"{method} {path} {protocol}\r\n"
                  f"Host: localhost\r\nConnection: {connection}\r\n\r\n").encode())


def read_response(sock, head=False):
    wire = bytearray()
    while b"\r\n\r\n" not in wire:
        part = sock.recv(65536)
        if not part:
            raise AssertionError("socket closed before response headers")
        wire.extend(part)
        if len(wire) > 32768:
            raise AssertionError("response headers unexpectedly large")
    head_wire, body = bytes(wire).split(b"\r\n\r\n", 1)
    lines = head_wire.decode("ascii").split("\r\n")
    headers = {}
    for line in lines[1:]:
        key, sep, value = line.partition(":")
        if not sep:
            raise AssertionError("malformed HTTP response header")
        headers[key.lower()] = value.strip()
    if not head:
        length = int(headers.get("content-length", "0"))
        while len(body) < length:
            part = sock.recv(min(65536, length - len(body)))
            if not part:
                raise AssertionError("early EOF in ordinary HTTP response")
            body += part
        if len(body) != length:
            raise AssertionError("unexpected extra HTTP bytes")
    elif body:
        raise AssertionError("HEAD response contained body bytes")
    return lines[0], headers, body


def fds(pid):
    return len(list((Path("/proc") / str(pid) / "fd").iterdir()))


def memory(pid):
    data = (Path("/proc") / str(pid) / "status").read_text()
    values = {}
    for line in data.splitlines():
        if line.startswith(("VmRSS:", "VmHWM:")):
            key, value = line.split(":", 1)
            values[key] = int(value.strip().split()[0])
    return values


def check_ping(port):
    with connect(port) as sock:
        request(sock, "/ping")
        status, headers, body = read_response(sock)
        assert status == "HTTP/1.1 200 OK", status
        assert headers["content-length"] == "4", headers
        assert body == b"pong", body


def check_head_keepalive(port):
    with connect(port) as sock:
        request(sock, "/head", "HEAD", connection="keep-alive")
        status, headers, body = read_response(sock, head=True)
        assert status == "HTTP/1.1 200 OK", status
        assert headers["content-length"] == str(len("head-test-content"))
        assert body == b""
        request(sock, "/ping", connection="close")
        status, _, body = read_response(sock)
        assert status == "HTTP/1.1 200 OK" and body == b"pong"


def check_native_headers(port):
    with connect(port) as sock:
        request(sock, "/native-headers")
        status, _, body = read_response(sock)
        assert status == "HTTP/1.1 200 OK" and body == b"data"


def check_upgrade_not_timed(port):
    with connect(port) as sock:
        request(sock, "/upgrade", connection="Upgrade")
        wire = bytearray()
        while b"\r\n\r\n" not in wire:
            part = sock.recv(1024)
            if not part:
                raise AssertionError("Upgrade response closed before handshake")
            wire.extend(part)
        assert wire.startswith(b"HTTP/1.1 101 Switching Protocols\r\n"), wire
        assert wire.endswith(b"\r\n\r\n"), wire
        # The Managed HTTP send deadline is 400ms; this arrives after 900ms.
        assert sock.recv(1) == b"Z", "upgraded socket was closed by HTTP deadline"
        sock.sendall(b"Q")
        assert sock.recv(1) == b"", "upgraded route did not close after EOF"


def check_slow_reader(port, pid, path):
    baseline_fds = fds(pid)
    sock = connect(port, rcvbuf=4096)
    try:
        request(sock, path)
        # Never read during the 400ms configured managed-send deadline.
        # With maxConnections=1, any remaining stalled connection prevents ping.
        time.sleep(1.3)
        fds_after_stall = fds(pid)
        if fds_after_stall > baseline_fds:
            raise AssertionError(
                f"managed sender retained FD: {fds_after_stall} > {baseline_fds}")
        check_ping(port)  # The only connection slot was reclaimed.
        # Socket-level receive/FIN timing is kernel-buffer dependent. Do not
        # require the peer to drain its receive window for reclamation proof.
        return {"fds_after_stall": fds_after_stall,
                "fds_after_ping": fds(pid),
                "memory_after_kib": memory(pid)}
    finally:
        sock.close()


def check_peer_disconnect(port):
    sock = connect(port, rcvbuf=4096)
    request(sock, "/large")
    sock.close()
    time.sleep(.7)
    check_ping(port)


def run_case(name, fn, results):
    try:
        value = fn()
        results.append({"name": name, "result": "PASS", "detail": value})
        print(f"PASS {name}")
    except Exception as exc:
        results.append({"name": name, "result": "FAIL", "detail": repr(exc)})
        print(f"FAIL {name}: {exc}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--mode", choices=("debug", "release"), required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    records = []
    baseline = {"fds": fds(args.pid), "memory_kib": memory(args.pid)}
    run_case("control_ping", lambda: check_ping(args.port), records)
    run_case("head_keepalive_get", lambda: check_head_keepalive(args.port), records)
    run_case("native_respond_headers", lambda: check_native_headers(args.port), records)
    run_case("respond_timeout_and_slot_reclaim",
             lambda: check_slow_reader(args.port, args.pid, "/large"), records)
    run_case("respond_headers_timeout_and_slot_reclaim",
             lambda: check_slow_reader(args.port, args.pid, "/native-large"), records)
    run_case("peer_disconnect_recovery", lambda: check_peer_disconnect(args.port), records)
    run_case("upgrade_outlives_managed_deadline",
             lambda: check_upgrade_not_timed(args.port), records)
    run_case("control_ping_after_probes", lambda: check_ping(args.port), records)
    time.sleep(.25)
    final = {"fds": fds(args.pid), "memory_kib": memory(args.pid)}
    if final["fds"] > baseline["fds"] + 1:
        records.append({"name": "fd_reclamation", "result": "FAIL",
                        "detail": {"before": baseline, "after": final}})
    else:
        records.append({"name": "fd_reclamation", "result": "PASS",
                        "detail": {"before": baseline, "after": final}})
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / f"js05-{args.mode}.json").write_text(
        json.dumps({"mode": args.mode, "settings": {"managedSendTimeoutMs": 400},
                    "tests": records}, indent=2), encoding="utf-8")
    if any(item["result"] != "PASS" for item in records):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
