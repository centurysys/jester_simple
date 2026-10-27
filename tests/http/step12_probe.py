#!/usr/bin/env python3
"""Step 12: raw response ordering, bounded queue and disconnect tests."""
from __future__ import annotations
import http.client
import json
import os
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HOST = '127.0.0.1'


def get(path: str, port=5492, *, slow=False, connection=None):
    owned = connection is None
    conn = connection or http.client.HTTPConnection(HOST, port, timeout=15)
    try:
        conn.request('GET', path)
        response = conn.getresponse()
        status = response.status
        if slow:
            body = bytearray()
            while True:
                chunk = response.read(4096)
                if not chunk:
                    break
                body.extend(chunk)
                time.sleep(0.002)
            body = bytes(body)
        else:
            body = response.read()
        return status, body
    finally:
        if owned:
            conn.close()


def get_partial_then_disconnect():
    sock = socket.create_connection((HOST, 5492), timeout=5)
    try:
        sock.sendall(b'GET /disconnect HTTP/1.1\r\nHost: localhost\r\n'
                     b'Connection: close\r\n\r\n')
        sock.recv(1024)
    finally:
        sock.close()


def collect_early_response(path):
    sock = socket.create_connection((HOST, 5492), timeout=4)
    sock.settimeout(2)
    data = bytearray()
    try:
        sock.sendall((f'GET {path} HTTP/1.1\r\nHost: localhost\r\n'
                      'Connection: close\r\n\r\n').encode())
        for _ in range(16):
            try:
                chunk = sock.recv(8192)
            except (TimeoutError, ConnectionResetError, OSError):
                break
            if not chunk:
                break
            data.extend(chunk)
        return bytes(data)
    finally:
        sock.close()


def main():
    out, mode = Path(sys.argv[1]), sys.argv[2]
    server_pid = int(sys.argv[3])
    rows = []

    def record(name, action, expected):
        try:
            actual = action()
            ok = bool(actual)
            rows.append({'name': name, 'result': 'PASS' if ok else 'FAIL',
                         'expected': expected, 'detail': '' if ok else str(actual)[:200]})
        except Exception as exc:
            rows.append({'name': name, 'result': 'FAIL',
                         'expected': expected, 'detail': repr(exc)})

    record('normal_control', lambda: get('/ping') == (200, b'pong'), '200 pong')
    record('legacy_send_order', lambda: get('/legacy') == (200, b'abcdefghijkl'), 'ordered body')
    record('raw_async_large', lambda: get('/async') == (200, b'aB09' * (128 * 1024)), '512KiB')
    record('mixed_send_order', lambda: get('/mixed') == (200, b'0123456789'), 'ordered body')
    record('slow_reader', lambda: get('/async', slow=True) ==
           (200, b'aB09' * (128 * 1024)), '512KiB slow reader')

    def sequential_keepalive():
        conn = http.client.HTTPConnection(HOST, 5492, timeout=10)
        try:
            first = get('/mixed', connection=conn)
            second = get('/ping', connection=conn)
            return first == (200, b'0123456789') and second == (200, b'pong')
        finally:
            conn.close()
    record('raw_then_keepalive', sequential_keepalive, 'two valid responses')

    def no_double_response(path):
        data = collect_early_response(path)
        # If a partial raw header was sent, a later error page must not add
        # a second HTTP status line. A hard close is acceptable.
        return data.count(b'HTTP/1.1 ') <= 1
    record('legacy_queue_overflow', lambda: no_double_response('/overflow'),
           'no duplicate status line')
    record('missing_raw_mode', lambda: no_double_response('/without-raw'),
           'no duplicate status line')
    record('fast_sync_raw', lambda: get('/', port=5493) == (200, b'solo'),
           '200 solo, single matcher')
    def measure_fd_recovery():
        baseline = len(os.listdir(f'/proc/{server_pid}/fd'))
        for _ in range(4):
            get_partial_then_disconnect()
        time.sleep(1.0)
        remaining = len(os.listdir(f'/proc/{server_pid}/fd'))
        return remaining <= baseline + 6
    record('fd_recovery_after_disconnect', measure_fd_recovery,
           'FD count returns near baseline after four aborts')
    record('recovery_after_disconnect', lambda: get('/ping') == (200, b'pong'),
           '200 pong')

    passed = sum(r['result'] == 'PASS' for r in rows)
    summary = {'mode': mode, 'captured_utc': datetime.now(timezone.utc).isoformat(),
               'passed': passed, 'total': len(rows), 'results': rows}
    out.mkdir(parents=True, exist_ok=True)
    (out / f'step12-{mode}.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f'Step 12 {mode}: {passed}/{len(rows)} PASS')
    for row in rows:
        if row['result'] != 'PASS':
            print('FAIL', row['name'], row['detail'])
    return 0 if passed == len(rows) else 1


if __name__ == '__main__':
    raise SystemExit(main())
