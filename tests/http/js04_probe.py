#!/usr/bin/env python3
"""JS-04: Loopback HTTP Upgrade ownership and Connection token regression.

The upgraded data stream uses single-byte commands; it is NOT WebSocket.
"""
import argparse
import json
import os
import socket
import time
from pathlib import Path

HOST = "127.0.0.1"


def connect(port):
    sock = socket.create_connection((HOST, port), timeout=1.5)
    sock.settimeout(1.5)
    return sock


def request(sock, path, *, version="HTTP/1.1", connection="close",
            upgrade=None):
    fields = [f"GET {path} {version}", "Host: localhost",
              f"Connection: {connection}"]
    if upgrade is not None:
        fields.append(f"Upgrade: {upgrade}")
    sock.sendall(("\r\n".join(fields) + "\r\n\r\n").encode("ascii"))


def read_response(sock, carry=b""):
    data = bytearray(carry)
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(8192)
        if not chunk:
            raise AssertionError("EOF while reading HTTP headers")
        data.extend(chunk)
        if len(data) > 32768:
            raise AssertionError("oversized test response headers")
    header, remainder = bytes(data).split(b"\r\n\r\n", 1)
    fields = header.split(b"\r\n")
    status = int(fields[0].split(b" ", 2)[1])
    lengths = [x.split(b":", 1)[1].strip() for x in fields[1:]
               if x.lower().startswith(b"content-length:")]
    size = int(lengths[0]) if lengths else 0
    while len(remainder) < size:
        chunk = sock.recv(8192)
        if not chunk:
            raise AssertionError("EOF within HTTP response body")
        remainder += chunk
    return status, remainder[:size], remainder[size:]


def take(sock, n):
    data = b""
    while len(data) < n:
        part = sock.recv(n - len(data))
        if not part:
            raise AssertionError("unexpected EOF during upgraded payload")
        data += part
    return data


def assert_eof(sock):
    try:
        data = sock.recv(128)
    except ConnectionResetError:
        return
    assert data == b"", f"connection did not close: {data!r}"


def open_upgrade(port, connection="Keep-Alive, uPgRaDe"):
    sock = connect(port)
    try:
        request(sock, "/upgrade", connection=connection,
                upgrade="js04-test")
        status, body, carry = read_response(sock)
        assert status == 101 and body == b"" and carry == b"", (
            status, body, carry)
        return sock
    except BaseException:
        sock.close()
        raise


def fd_count(pid):
    return len(os.listdir(f"/proc/{pid}/fd"))


def wait_fd_at_most(pid, maximum, seconds=1.5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        count = fd_count(pid)
        if count <= maximum:
            return count
        time.sleep(0.03)
    return fd_count(pid)


def check_http_reuse(port, value, version="HTTP/1.1"):
    with connect(port) as sock:
        request(sock, "/plain", version=version, connection=value)
        status, body, carry = read_response(sock)
        assert (status, body, carry) == (200, b"plain", b"")
        request(sock, "/ping", connection="close")
        status, body, carry = read_response(sock, carry)
        assert (status, body, carry) == (200, b"pong", b"")
        assert_eof(sock)


def check_http_close(port, value, version="HTTP/1.1"):
    with connect(port) as sock:
        request(sock, "/plain", version=version, connection=value)
        status, body, carry = read_response(sock)
        assert (status, body, carry) == (200, b"plain", b"")
        assert_eof(sock)


def check_echo_lifetime(port):
    with open_upgrade(port) as sock:
        time.sleep(0.35)
        sock.sendall(b"P")
        assert take(sock, 2) == b"EP"
        # Protocol bytes must go to the upgraded route, not the HTTP parser.
        sock.sendall(b"G")
        assert take(sock, 2) == b"EG"
        sock.sendall(b"Q")
        assert_eof(sock)


def check_rejected_handshake(port):
    with connect(port) as sock:
        request(sock, "/upgrade", connection="not-upgrade, close",
                upgrade="js04-test")
        status, body, carry = read_response(sock)
        assert (status, body, carry) == (400, b"invalid-upgrade", b"")
        assert_eof(sock)


def check_exception(port):
    with connect(port) as sock:
        request(sock, "/upgrade-error", connection="Upgrade",
                upgrade="js04-test")
        status, body, carry = read_response(sock)
        assert status == 101 and body == b"" and carry == b""
        assert_eof(sock)  # no second HTTP 500
    with connect(port) as sock:
        request(sock, "/ping")
        status, body, carry = read_response(sock)
        assert (status, body, carry) == (200, b"pong", b"")


def check_capacity_and_eof(port, pid, baseline):
    a = open_upgrade(port)
    b = open_upgrade(port)
    try:
        with connect(port) as third:
            request(third, "/ping")
            assert_eof(third)  # maxConnections = 2; no HTTP response

        # A peer disconnect must allow recv() to finish and release its slot.
        a.close()
        deadline = time.monotonic() + 1.5
        recovered = False
        while time.monotonic() < deadline:
            try:
                with connect(port) as sock:
                    request(sock, "/ping")
                    status, body, _ = read_response(sock)
                    if status == 200 and body == b"pong":
                        recovered = True
                        break
            except (OSError, AssertionError):
                time.sleep(0.03)
        assert recovered, "connection slot not reclaimed after peer EOF"
        b.sendall(b"P")
        assert take(b, 2) == b"EP"
        b.sendall(b"Q")
        assert_eof(b)
    finally:
        a.close()
        b.close()
    final = wait_fd_at_most(pid, baseline + 2)
    assert final <= baseline + 2, ("FDs not reclaimed", baseline, final)


def check_fd_cycles(port, pid, baseline):
    for _ in range(16):
        with open_upgrade(port) as sock:
            sock.sendall(b"Q")
            assert_eof(sock)
    final = wait_fd_at_most(pid, baseline + 2)
    assert final <= baseline + 2, ("FD growth", baseline, final)
    return final


def run(name, action, results):
    start = time.monotonic()
    try:
        outcome = action()
        result, detail = "PASS", "" if outcome is None else str(outcome)
    except Exception as exc:  # Preserve all failures in JSON before exiting.
        result, detail = "FAIL", f"{type(exc).__name__}: {exc}"
    results.append({"name": name, "result": result,
                    "elapsed_seconds": round(time.monotonic() - start, 3),
                    "detail": detail})
    print(f"{result} {name}" + (f": {detail}" if detail else ""), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--mode", choices=("debug", "release"), required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    results = []
    baseline = fd_count(args.pid)

    run("http11_substring_not_upgrade",
        lambda: check_http_reuse(args.port, "keep-alive, not-upgrade"), results)
    run("http11_upgrade_offer_not_accepted",
        lambda: check_http_reuse(args.port, "keep-alive, Upgrade"), results)
    run("http11_mixed_case_upgrade_offer",
        lambda: check_http_reuse(args.port, "uPgRaDe"), results)
    run("http11_close_in_list",
        lambda: check_http_close(args.port, "keep-alive, CLOSE"), results)
    run("http11_close_first",
        lambda: check_http_close(args.port, "close, keep-alive"), results)
    run("http11_not_close_substring",
        lambda: check_http_reuse(args.port, "keep-alive, closeish"), results)
    run("http10_keepalive_in_list",
        lambda: check_http_reuse(args.port, "Upgrade, Keep-Alive", "HTTP/1.0"),
        results)
    run("http10_close_override",
        lambda: check_http_close(args.port, "keep-alive, close", "HTTP/1.0"),
        results)
    run("http10_without_keepalive",
        lambda: check_http_close(args.port, "Upgrade", "HTTP/1.0"), results)
    run("upgrade_validation_rejects_substring",
        lambda: check_rejected_handshake(args.port), results)
    run("upgraded_route_lifetime_and_no_http_parser",
        lambda: check_echo_lifetime(args.port), results)
    run("post101_exception_closes_without_500",
        lambda: check_exception(args.port), results)
    run("connection_cap_and_peer_eof_reclamation",
        lambda: check_capacity_and_eof(args.port, args.pid, baseline), results)
    run("fd_reclamation_16_cycles",
        lambda: check_fd_cycles(args.port, args.pid, baseline), results)
    args.out.mkdir(parents=True, exist_ok=True)
    path = args.out / f"js04-{args.mode}.json"
    path.write_text(json.dumps({"mode": args.mode, "initial_fds": baseline,
                                "tests": results}, indent=2) + "\n",
                    encoding="utf-8")
    if any(item["result"] != "PASS" for item in results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
