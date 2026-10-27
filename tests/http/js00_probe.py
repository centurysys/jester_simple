#!/usr/bin/env python3
"""JS-00: observe known issues without mistaking expected defects for failures.

This is a transport-level HTTP probe; upgrade fixtures do not implement RFC 6455.
Run only against the matching server bound to 127.0.0.1:5510.
"""
from __future__ import annotations

import argparse
import http.client
import json
import os
import socket
import time
from datetime import datetime, timezone
from pathlib import Path

HOST = "127.0.0.1"
PORT = 5510
HEAD_BODY = b"js00-managed-head-body"
ERROR_BODY = b"js00-managed-error-body"
SECRETS = (
    "JS00_MANAGED_COOKIE_SECRET_781",
    "JS00_SECOND_COOKIE_SECRET_782",
    "JS00_RAW_COOKIE_SECRET_783",
)


def http_get(path: str) -> tuple[int, list[tuple[str, str]], bytes]:
    conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
    try:
        conn.request("GET", path, headers={"Connection": "close"})
        response = conn.getresponse()
        return response.status, response.getheaders(), response.read()
    finally:
        conn.close()


def raw_socket() -> socket.socket:
    sock = socket.create_connection((HOST, PORT), timeout=4)
    sock.settimeout(4)
    return sock


def raw_request(path: str, method="GET", connection="close") -> bytes:
    with raw_socket() as sock:
        sock.sendall((f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n"
                      f"Connection: {connection}\r\n\r\n").encode("ascii"))
        data = bytearray()
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                return bytes(data)
            data.extend(chunk)
            if len(data) > 1024 * 1024:
                raise AssertionError("Unexpectedly large raw response")


def parse_headers(raw: bytes) -> tuple[int, dict[str, str], bytes]:
    header, sep, body = raw.partition(b"\r\n\r\n")
    if not sep:
        raise AssertionError("HTTP response headers were not terminated")
    lines = header.split(b"\r\n")
    status = int(lines[0].split(b" ", 2)[1])
    fields = {}
    for line in lines[1:]:
        key, mark, value = line.partition(b":")
        if not mark:
            raise AssertionError(f"Malformed HTTP header: {line[:80]!r}")
        fields[key.decode("ascii").lower()] = value.strip().decode("latin-1")
    return status, fields, body


def read_headers(sock: socket.socket) -> tuple[bytes, bytes]:
    raw = bytearray()
    while b"\r\n\r\n" not in raw:
        chunk = sock.recv(4096)
        if not chunk:
            raise AssertionError("EOF before complete response headers")
        raw.extend(chunk)
        if len(raw) > 32768:
            raise AssertionError("Unexpected response header size")
    head, body = bytes(raw).split(b"\r\n\r\n", 1)
    return head + b"\r\n\r\n", body


def fd_count(pid: int) -> int | None:
    try:
        return len(os.listdir(f"/proc/{pid}/fd"))
    except OSError:
        return None


def resource_status(pid: int) -> dict[str, int | None]:
    record: dict[str, int | None] = {"fds": fd_count(pid), "vmrss_kib": None,
                                     "vmhwm_kib": None}
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                record["vmrss_kib"] = int(line.split()[1])
            if line.startswith("VmHWM:"):
                record["vmhwm_kib"] = int(line.split()[1])
    except OSError:
        pass
    return record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--mode", choices=("debug", "release"), required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--server-log", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    controls: list[dict] = []
    observations: list[dict] = []

    def control(name: str, check):
        try:
            detail = check()
            ok = detail is True
            controls.append({"name": name, "result": "PASS" if ok else "FAIL",
                             "detail": "" if ok else str(detail)[:350]})
        except Exception as exc:
            controls.append({"name": name, "result": "FAIL", "detail": repr(exc)})

    def observe(name: str, check):
        try:
            status, detail = check()
            observations.append({"name": name, "status": status, "detail": detail})
        except Exception as exc:
            observations.append({"name": name, "status": "INCONCLUSIVE",
                                 "detail": repr(exc)})

    control("control_ping", lambda: http_get("/ping")[::2] == (200, b"pong"))
    control("control_managed_get", lambda: http_get("/managed-head")[::2] ==
            (200, HEAD_BODY))

    def head_body(path: str, expected: bytes, expected_code: int):
        status, fields, body = parse_headers(raw_request(path, "HEAD"))
        if status != expected_code:
            return "INCONCLUSIVE", {"status": status}
        if fields.get("content-length") != str(len(expected)):
            return "INCONCLUSIVE", {"content_length": fields.get("content-length"),
                                    "expected": len(expected)}
        return ("DEFECT_OBSERVED" if body else "NOT_OBSERVED",
                {"wire_body_length": len(body), "wire_body_prefix": body[:60].decode(
                    "latin-1"), "content_length": fields.get("content-length")})

    observe("managed_head_wire_body", lambda: head_body(
        "/managed-head", HEAD_BODY, 200))
    observe("managed_error_head_wire_body", lambda: head_body(
        "/managed-error", ERROR_BODY, 404))

    def keepalive_head_get():
        with raw_socket() as sock:
            sock.sendall(b"HEAD /managed-head HTTP/1.1\r\nHost: localhost\r\n\r\n")
            head, trailing = read_headers(sock)
            status, fields, _ = parse_headers(head)
            if status != 200 or fields.get("content-length") != str(len(HEAD_BODY)):
                return "INCONCLUSIVE", {"head_status": status, "headers": fields}
            sock.sendall(b"GET /ping HTTP/1.1\r\nHost: localhost\r\n"
                         b"Connection: close\r\n\r\n")
            payload = bytearray(trailing)
            while True:
                chunk = sock.recv(8192)
                if not chunk:
                    break
                payload.extend(chunk)
                if len(payload) > 16384:
                    return "INCONCLUSIVE", {"reason": "oversized response"}
            subsequent = bytes(payload)
            at = subsequent.find(b"HTTP/1.1 ")
            if at < 0:
                return "INCONCLUSIVE", {"wire": repr(subsequent[:120])}
            get_status, _, get_body = parse_headers(subsequent[at:])
            if get_status != 200 or get_body != b"pong":
                return "INCONCLUSIVE", {"next_status": get_status,
                                        "next_body": repr(get_body[:120])}
            return ("DEFECT_OBSERVED" if at != 0 else "NOT_OBSERVED",
                    {"unexpected_bytes_before_next_response": at,
                     "prefix": repr(subsequent[:min(80, at)])})

    observe("managed_head_keepalive_desync", keepalive_head_get)

    def cookies():
        managed = http_get("/cookie-managed")
        raw = http_get("/cookie-raw")
        count = lambda value: sum(key.lower() == "set-cookie" for key, _ in value[1])
        return managed, raw, count(managed), count(raw)

    try:
        managed, raw, managed_n, raw_n = cookies()
        control("cookie_response_fields", lambda: managed[0] == raw[0] == 200
                and managed_n == 2 and raw_n == 1
                and managed[2] == b"managed-cookie-ok" and raw[2] == b"ok")
    except Exception as exc:
        controls.append({"name": "cookie_response_fields", "result": "FAIL",
                         "detail": repr(exc)})

    def cookie_log():
        time.sleep(0.15)
        log = args.server_log.read_text(encoding="utf-8", errors="replace")
        exposed = [secret for secret in SECRETS if secret in log]
        return ("DEFECT_OBSERVED" if exposed else "NOT_OBSERVED",
                {"mode": args.mode, "secret_count": len(exposed),
                 "managed_exposed": any(s in exposed for s in SECRETS[:2]),
                 "raw_exposed": SECRETS[2] in exposed})

    observe("cookie_secrets_in_server_log", cookie_log)

    def upgraded_exception():
        response = raw_request("/upgrade-exception", connection="upgrade")
        code, _, body = parse_headers(response)
        if code != 101:
            return "INCONCLUSIVE", {"status": code, "wire": repr(response[:120])}
        duplicate = b"HTTP/1.1 " in body
        return ("DEFECT_OBSERVED" if duplicate else "NOT_OBSERVED",
                {"second_http_status": duplicate, "bytes_after_101": len(body),
                 "wire_after_101": repr(body[:130])})

    observe("direct_upgrade_exception_double_response", upgraded_exception)

    def upgrade_lifetime(connection: str):
        with raw_socket() as sock:
            sock.sendall(("GET /upgrade-lifetime HTTP/1.1\r\n"
                          "Host: localhost\r\nConnection: " + connection +
                          "\r\nUpgrade: websocket\r\n\r\n").encode("ascii"))
            header, initial = read_headers(sock)
            code, _, _ = parse_headers(header)
            if code != 101:
                return "INCONCLUSIVE", {"status": code}
            sock.settimeout(2.0)
            started = time.monotonic()
            try:
                tail = sock.recv(4096)
            except socket.timeout:
                return "NOT_CLOSED_PROMPTLY", {"waited_seconds": 2.0,
                                               "initial_bytes": len(initial)}
            return ("CLOSED" if not tail else "EXTRA_DATA",
                    {"seconds_to_next_read": round(time.monotonic()-started, 3),
                     "extra_bytes": len(tail)})

    observe("upgrade_lifetime_connection_lowercase", lambda: upgrade_lifetime("upgrade"))
    observe("upgrade_lifetime_connection_titlecase", lambda: upgrade_lifetime("Upgrade"))

    def stalled_managed_send():
        before = resource_status(args.pid)
        with raw_socket() as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            sock.sendall(b"GET /managed-large HTTP/1.1\r\nHost: localhost\r\n"
                         b"Connection: close\r\n\r\n")
            # Do not read any response bytes: this measures slot retention,
            # not a definitive absence of all possible send deadlines.
            time.sleep(2.0)
            during = resource_status(args.pid)
            ping_ok = http_get("/ping")[::2] == (200, b"pong")
        time.sleep(0.15)
        after = resource_status(args.pid)
        held = (before["fds"] is not None and during["fds"] is not None and
                during["fds"] > before["fds"])
        return ("CONNECTION_HELD" if held else "NOT_OBSERVED",
                {"seconds_without_reading": 2.0, "before": before, "during": during,
                 "after_close": after, "parallel_ping_ok": ping_ok,
                 "note": "2 seconds of retention alone does not prove no deadline"})

    observe("managed_send_to_nonreading_peer", stalled_managed_send)
    control("control_ping_after_probes", lambda: http_get("/ping")[::2] ==
            (200, b"pong"))

    record = {
        "mode": args.mode,
        "captured_utc": datetime.now(timezone.utc).isoformat(),
        "controls": controls,
        "observations": observations,
        "server_resources_after": resource_status(args.pid),
    }
    destination = args.out / f"js00-{args.mode}.json"
    destination.write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n")
    bad = [row for row in controls if row["result"] != "PASS"]
    print(f"JS-00 {args.mode}: {len(controls)-len(bad)}/{len(controls)} controls PASS")
    for item in observations:
        print(f"  {item['name']}: {item['status']}")
    for item in bad:
        print(f"  CONTROL FAIL {item['name']}: {item['detail']}")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
