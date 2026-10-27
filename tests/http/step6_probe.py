#!/usr/bin/env python3
"""Step 6 acceptance: local-only HTTP timeouts, limits, and slot recovery."""
from __future__ import annotations

import json
import os
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HOST, PORT = '127.0.0.1', 5482


def conn() -> socket.socket:
    s = socket.create_connection((HOST, PORT), timeout=1)
    s.settimeout(1.8)
    return s


def req(method='GET', path='/step6/ping', fields=(), body=b'') -> bytes:
    return (f'{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\n'
            + ''.join(f'{h}\r\n' for h in fields) + '\r\n').encode() + body


def status(data: bytes) -> int | None:
    line = data.split(b'\r\n', 1)[0].split(b' ', 2)
    return int(line[1]) if len(line) > 1 and line[1].isdigit() else None


def exchange(data: bytes) -> bytes:
    with conn() as s:
        s.sendall(data)
        s.shutdown(socket.SHUT_WR)
        return recv_all(s)


def recv_all(s: socket.socket) -> bytes:
    out = bytearray()
    try:
        while len(out) < 128 * 1024:
            got = s.recv(4096)
            if not got:
                break
            out.extend(got)
    except (OSError, socket.timeout):
        pass
    return bytes(out)


def wait_closed(s: socket.socket, seconds=2.0) -> bool:
    until = time.monotonic() + seconds
    s.settimeout(0.25)
    while time.monotonic() < until:
        try:
            if not s.recv(4096):
                return True
        except (ConnectionResetError, BrokenPipeError):
            return True
        except socket.timeout:
            continue
        except OSError:
            return True
    return False


def test_header_timeout() -> bool:
    with conn() as s:
        s.sendall(b'GET /step6/ping HTTP/1.1\r\nHost:')
        return wait_closed(s)


def test_idle_no_bytes() -> bool:
    with conn() as s:
        return wait_closed(s)


def test_slow_header_trickle() -> bool:
    with conn() as s:
        s.sendall(b'GET /step6/ping HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Slow:')
        # The deadline is fixed from accept, not extended by each byte.
        for _ in range(9):
            time.sleep(0.12)
            try:
                s.sendall(b'X')
            except OSError:
                return True
        return wait_closed(s, seconds=0.7)


def test_body_timeout(chunked=False) -> bool:
    with conn() as s:
        if chunked:
            s.sendall(req('POST', '/step6/body',
                          ['Transfer-Encoding: chunked'], b'A\r\nab'))
        else:
            s.sendall(req('POST', '/step6/body', ['Content-Length: 10'], b'ab'))
        return wait_closed(s)


def test_keepalive_timeout() -> bool:
    with conn() as s:
        s.sendall(req())
        raw = bytearray()
        while b'pong' not in raw and len(raw) < 4096:
            raw.extend(s.recv(4096))
        return status(bytes(raw)) == 200 and wait_closed(s)


def test_header_fields() -> bool:
    names = [f'X-Test-{n}: v' for n in range(14)]
    return status(exchange(req(fields=names))) == 431


def test_header_bytes() -> bool:
    return status(exchange(req(fields=['X-Big: ' + 'A' * 1200]))) == 431


def test_boundary_fields() -> bool:
    # Includes Host in the count: 12 field lines are permitted.
    names = [f'X-Ok-{n}: v' for n in range(11)]
    return status(exchange(req(fields=names))) == 200


def test_recovery_capacity() -> bool:
    held = []
    try:
        for _ in range(3):
            held.append(conn())
        time.sleep(0.1)
        # At capacity the fourth connection should be closed, not queued
        # indefinitely or serviced by another request parser.
        with conn() as excess:
            try:
                excess.sendall(req())
            except OSError:
                pass
            overflow_closed = wait_closed(excess, 0.8)
        for s in held:
            s.close()
        held.clear()
        time.sleep(0.4)
        recovered = status(exchange(req())) == 200
        return overflow_closed and recovered
    finally:
        for s in held:
            s.close()


def test_fd_recovery(pid: int) -> bool:
    directory = Path(f'/proc/{pid}/fd')
    if not directory.is_dir():
        return False
    before = len(os.listdir(directory))
    for _ in range(30):
        if status(exchange(req())) != 200:
            return False
    time.sleep(0.65)
    after = len(os.listdir(directory))
    return after <= before + 2


def test_chunked_control() -> bool:
    data = req('POST', '/step6/body', ['Transfer-Encoding: chunked'],
               b'3\r\nabc\r\n0\r\n\r\n')
    raw = exchange(data)
    return status(raw) == 200 and raw.endswith(b'3')


def main() -> int:
    out = Path(sys.argv[1])
    pid = int(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    cases = []
    tests = [
        ('get_control', lambda: status(exchange(req())) == 200),
        ('post_control', lambda: status(exchange(
            req('POST', '/step6/body', ['Content-Length: 3'], b'abc'))) == 200),
        ('chunked_control', test_chunked_control),
        ('header_timeout_partial', test_header_timeout),
        ('header_timeout_no_data', test_idle_no_bytes),
        ('header_timeout_trickle', test_slow_header_trickle),
        ('content_length_body_timeout', test_body_timeout),
        ('chunked_body_timeout', lambda: test_body_timeout(True)),
        ('keepalive_idle_timeout', test_keepalive_timeout),
        ('header_fields_above_limit', test_header_fields),
        ('header_bytes_above_limit', test_header_bytes),
        ('header_fields_exact_limit', test_boundary_fields),
        ('connection_capacity_recovery', test_recovery_capacity),
        ('fd_recovery_after_requests', lambda: test_fd_recovery(pid)),
        ('post_probe_ping', lambda: status(exchange(req())) == 200),
    ]
    for name, run in tests:
        try:
            ok, error = bool(run()), ''
        except Exception as exc:
            ok, error = False, f'{type(exc).__name__}: {exc}'
        cases.append(dict(name=name, ok=ok, error=error))
        print(f"{'PASS' if ok else 'FAIL'} {name} {error}", flush=True)
    total = len(cases)
    count = sum(x['ok'] for x in cases)
    (out / 'observations.json').write_text(json.dumps({
        'utc': datetime.now(timezone.utc).isoformat(),
        'server_pid': pid, 'total': total, 'passed': count, 'tests': cases
    }, ensure_ascii=False, indent=2) + '\n')
    lines = ['# Step 6 HTTP resource limits', '',
             f'Passed: {count} / {total}', '',
             '| Test | Result | Note |', '| --- | --- | --- |']
    for row in cases:
        lines.append(f"| {row['name']} | {'PASS' if row['ok'] else 'FAIL'} | "
                     f"{row['error'].replace('|', '/')[:100]} |")
    (out / 'REPORT.md').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines))
    return 0 if count == total else 1


if __name__ == '__main__':
    sys.exit(main())
