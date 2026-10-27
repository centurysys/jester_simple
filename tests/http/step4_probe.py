#!/usr/bin/env python3
"""Read-only local HTTP transport characterization for Jester Simple Step 4.

Uses only Python's standard library as a raw TCP test client. Never connects to
non-loopback addresses, never changes the server or marks known bugs as passes.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HOST = "127.0.0.1"
PORT = 5481
MAX_BODY = 64 * 1024  # Must match step4_server.nim
TIMEOUT = 2.0


def make_request(method: str, path: str, headers: list[str], body: bytes = b"") -> bytes:
    lines = [f"{method} {path} HTTP/1.1", "Host: 127.0.0.1:5481", "Connection: close"]
    lines.extend(headers)
    return ("\r\n".join(lines) + "\r\n\r\n").encode("ascii") + body


def recv_response(sock: socket.socket, timeout: float = TIMEOUT) -> dict:
    sock.settimeout(timeout)
    raw = bytearray()
    header_end = -1
    content_length = None
    observed_close = False
    timed_out = False
    try:
        while len(raw) < 256 * 1024:
            chunk = sock.recv(4096)
            if not chunk:
                observed_close = True
                break
            raw.extend(chunk)
            if header_end < 0:
                header_end = raw.find(b"\r\n\r\n")
                if header_end >= 0:
                    for header in raw[:header_end].split(b"\r\n")[1:]:
                        k, sep, v = header.partition(b":")
                        if sep and k.lower() == b"content-length":
                            try:
                                content_length = int(v.strip())
                            except ValueError:
                                pass
            if header_end >= 0 and content_length is not None:
                if len(raw) - (header_end + 4) >= content_length:
                    break
    except socket.timeout:
        timed_out = True
    except OSError as exc:
        return {"status": None, "socket_error": str(exc), "raw_bytes": len(raw)}

    status = None
    status_line = ""
    if header_end >= 0:
        status_line = raw[: raw.find(b"\r\n")].decode("latin-1", errors="replace")
        parts = status_line.split(" ", 2)
        if len(parts) >= 2 and parts[1].isdigit():
            status = int(parts[1])
    return {
        "status": status,
        "status_line": status_line,
        "raw_bytes": len(raw),
        "body_bytes": max(0, len(raw) - (header_end + 4)) if header_end >= 0 else None,
        "content_length": content_length,
        "closed_observed": observed_close,
        "read_timed_out": timed_out,
        "body_sample": raw[header_end + 4 : header_end + 68].decode("latin-1", errors="replace")
        if header_end >= 0 else "",
    }


def send_probe(name: str, category: str, payload: bytes, *,
               shutdown_write: bool = False) -> dict:
    started = time.monotonic()
    result = {"name": name, "category": category, "request_bytes": len(payload)}
    try:
        with socket.create_connection((HOST, PORT), timeout=TIMEOUT) as sock:
            sock.settimeout(TIMEOUT)
            sock.sendall(payload)
            if shutdown_write:
                sock.shutdown(socket.SHUT_WR)
            result.update(recv_response(sock))
    except (OSError, TimeoutError) as exc:
        result.update({"status": None, "socket_error": str(exc)})
    result["elapsed_ms"] = round((time.monotonic() - started) * 1000, 2)
    return result


def chunked(chunks: list[bytes], terminal: bool = True) -> bytes:
    output = bytearray()
    for data in chunks:
        output.extend(f"{len(data):X}\r\n".encode("ascii"))
        output.extend(data)
        output.extend(b"\r\n")
    if terminal:
        output.extend(b"0\r\n\r\n")
    return bytes(output)


def fd_count(pid: int) -> int | None:
    if pid <= 0:
        return None
    try:
        return len(os.listdir(f"/proc/{pid}/fd"))
    except (OSError, PermissionError):
        return None


def idle_connections(pid: int, count: int = 12, hold_seconds: float = 1.5) -> dict:
    before = fd_count(pid)
    conns = []
    failures = []
    try:
        for _ in range(count):
            try:
                conn = socket.create_connection((HOST, PORT), timeout=TIMEOUT)
                conn.sendall(b"GET /step4/ping HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Pending: ")
                conns.append(conn)
            except OSError as exc:
                failures.append(str(exc))
        time.sleep(hold_seconds)
        during = fd_count(pid)
        for conn in conns:
            conn.close()
        conns.clear()
        time.sleep(0.5)
        after = fd_count(pid)
        return {
            "name": "incomplete_header_connections",
            "category": "resource_observation",
            "requested": count,
            "opened": count - len(failures),
            "fd_before": before,
            "fd_while_open": during,
            "fd_after_close": after,
            "observed_for_seconds": hold_seconds,
            "connect_errors": failures[:3],
        }
    finally:
        for conn in conns:
            conn.close()


def do_probes(pid: int) -> dict:
    observations = []
    add = observations.append

    add(send_probe("get_ping", "control", make_request("GET", "/step4/ping", [])))
    add(send_probe("post_content_length_small", "control",
                   make_request("POST", "/step4/body", ["Content-Length: 4"], b"DATA")))
    # Content-Length exceeding maxBody must be rejected from headers alone.
    add(send_probe("content_length_above_max", "limit",
                   make_request("POST", "/step4/body", [f"Content-Length: {MAX_BODY + 1}"])))
    add(send_probe("chunked_small", "control",
                   make_request("POST", "/step4/body", ["Transfer-Encoding: chunked"],
                                chunked([b"hello", b"world"]))))
    add(send_probe("chunked_above_max", "limit",
                   make_request("POST", "/step4/body", ["Transfer-Encoding: chunked"],
                                chunked([b"X" * 20000] * 4))))
    add(send_probe("both_transfer_encoding_and_content_length", "framing",
                   make_request("POST", "/step4/body",
                                ["Content-Length: 4", "Transfer-Encoding: chunked"],
                                chunked([b"DATA"]))))
    add(send_probe("conflicting_content_lengths", "framing",
                   make_request("POST", "/step4/body",
                                ["Content-Length: 4", "Content-Length: 5"], b"HELLO")))
    add(send_probe("duplicated_same_content_length", "framing",
                   make_request("POST", "/step4/body",
                                ["Content-Length: 4", "Content-Length: 4"], b"DATA")))
    add(send_probe("invalid_content_length", "framing",
                   make_request("POST", "/step4/body", ["Content-Length: no"])))
    add(send_probe("invalid_chunk_size", "framing",
                   make_request("POST", "/step4/body", ["Transfer-Encoding: chunked"],
                                b"ZZ\r\n")))
    add(send_probe("chunked_missing_terminal_chunk", "framing",
                   make_request("POST", "/step4/body", ["Transfer-Encoding: chunked"],
                                chunked([b"abc"], terminal=False)), shutdown_write=True))
    add(send_probe("repeated_header_lines", "headers",
                   make_request("GET", "/step4/ping", ["X-Repeated: yes"] * 130)))
    add(send_probe("many_unique_header_lines", "headers",
                   make_request("GET", "/step4/ping",
                                [f"X-Number-{i}: x" for i in range(130)])))
    add(idle_connections(pid))
    add(send_probe("post_probe_ping", "control", make_request("GET", "/step4/ping", [])))
    return {"observations": observations}


def summarize(record: dict) -> tuple[str, list[str]]:
    rows = [
        "# Step 4 HTTP transport observations",
        "",
        "This is a characterization run on an intentionally unmodified server, NOT a security pass.",
        "Raw probes used only 127.0.0.1:5481 with an isolated dedicated test process.",
        "",
        f"- Captured UTC: {record['utc']}",
        f"- Process PID: {record['pid']}",
        f"- Body limit configured: {MAX_BODY} bytes",
        "- Execution environment: Linux, Python stdlib raw TCP test client",
        "",
        "| Probe | HTTP status | Observed bytes | Note |",
        "| --- | --- | ---: | --- |",
    ]
    concerns = []
    for item in record["observations"]:
        name = item["name"]
        status = item.get("status")
        if name == "incomplete_header_connections":
            before, during, after = (item.get(k) for k in
                                     ("fd_before", "fd_while_open", "fd_after_close"))
            note = f"FDs {before} → {during} → {after}; {item['opened']} sockets / 1.5s"
            rows.append(f"| {name} | n/a | n/a | {note} |")
            continue
        status_str = str(status) if status is not None else "none"
        note = ""
        if item.get("socket_error"):
            note = "Socket error (see JSON)"
        elif item.get("read_timed_out"):
            note = "Read timed out (see JSON)"
        if name == "chunked_above_max" and status == 200:
            concerns.append("Chunked POST exceeded maxBody and was accepted (200).")
        if name == "both_transfer_encoding_and_content_length" and status == 200:
            concerns.append("Conflicting Transfer-Encoding + Content-Length was accepted (200).")
        if name == "conflicting_content_lengths" and status == 200:
            concerns.append("Conflicting Content-Length fields were accepted (200).")
        rows.append(f"| {name} | {status_str} | {item.get('body_bytes')} | {note} |")
    rows += ["", "## Findings requiring Step 5/6 changes or further verification", ""]
    if concerns:
        rows.extend(f"- {concern}" for concern in concerns)
    else:
        rows.append("- No predefined acceptance concern was automatically confirmed; inspect JSON and sources.")
    rows += [
        "", "## Interpretation limits", "",
        "- A 200 response to malformed HTTP shows acceptance, not exploitation or request smuggling by itself.",
        "- A timeout or lack of response during the short observation window does not establish an infinite timeout.",
        "- The probe does not verify downstream proxy interpretation or actual peak heap allocations.",
        "- File descriptor counts can fluctuate due to the server event loop and process activity.",
        "- HTTP close/keep-alive and body framing must be checked from the raw JSON and original packets.",
        "- An incomplete-header test holds only 12 sockets for 1.5 seconds; it is not a stress test.",
        "- The suite intentionally does not abort on known security failures. Do not use a green exit status as acceptance.",
        "", "## Next decision", "",
        "Record the adopted transport strategy and implementation scope in docs/modernization/step4_transport_decision.md.",
        "",
    ]
    return "\n".join(rows), concerns


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True, help="PID of dedicated Step 4 server")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        with socket.create_connection((HOST, PORT), timeout=TIMEOUT):
            pass
    except OSError as exc:
        print(f"Step 4 server not reachable on {HOST}:{PORT}: {exc}", file=sys.stderr)
        return 2
    record = {
        "utc": datetime.now(timezone.utc).isoformat(),
        "host": HOST, "port": PORT, "pid": args.pid, "max_body": MAX_BODY,
    }
    record.update(do_probes(args.pid))
    md, concerns = summarize(record)
    record["suspected_concerns"] = concerns
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "observations.json").write_text(
        json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (args.output / "REPORT.md").write_text(md, encoding="utf-8")
    print(md)
    # Do not treat vulnerable behavior as test harness failure in Step 4.
    controls = {obs["name"]: obs for obs in record["observations"]}
    expected = {"get_ping": 200, "post_content_length_small": 200,
                "chunked_small": 200, "post_probe_ping": 200}
    failed = [name for name, code in expected.items() if controls[name].get("status") != code]
    if failed:
        print("ERROR: valid control probes failed: " + ", ".join(failed), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
