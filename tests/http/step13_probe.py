#!/usr/bin/env python3
"""Loopback-only Step 13 FD-based static file containment regression."""
from __future__ import annotations

import http.client
import json
import os
import socket
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path

HOST, PORT = '127.0.0.1', 5494


def request(path: str, headers: dict | None = None):
    conn = http.client.HTTPConnection(HOST, PORT, timeout=15)
    try:
        conn.request('GET', path, headers=headers or {})
        response = conn.getresponse()
        return response.status, response.read(), dict(response.getheaders())
    finally:
        conn.close()


def main():
    out, mode, root, pid = (Path(sys.argv[1]), sys.argv[2],
                            Path(sys.argv[3]), int(sys.argv[4]))
    parent = root.parent
    outside = parent / 'outside-secret.txt'
    outside.write_bytes(b'OUTSIDE-DATA-MUST-NOT-LEAK-1349')
    sibling = parent / 'public-backup'
    sibling.mkdir(exist_ok=True)
    (sibling / 'secret.txt').write_bytes(b'SIBLING-SECRET-MUST-NOT-LEAK')
    (root / 'sub').mkdir(exist_ok=True)
    (root / 'ok.txt').write_bytes(b'root-ok')
    (root / 'sub' / 'inside.txt').write_bytes(b'nested-ok')
    (root / 'index.html').write_bytes(b'root-index')
    (root / 'sub' / 'index.htm').write_bytes(b'sub-index')
    (root / 'sp ace.txt').write_bytes(b'space-ok')
    (root / 'pct%2f.txt').write_bytes(b'encoded-once')
    (root / 'private.txt').write_bytes(b'not-world-readable')
    (root / 'private.txt').chmod(0o600)
    (root / 'out-file').symlink_to(outside)
    (root / 'out-dir').symlink_to(sibling, target_is_directory=True)
    (root / 'broken').symlink_to(parent / 'missing-secret')
    (root / 'cycle').symlink_to(root, target_is_directory=True)
    os.mkfifo(root / 'fifo', 0o644)
    large_body = (b'step13!!' * 1_250_000)  # Exactly 10,000,000 bytes.
    (root / 'large.bin').write_bytes(large_body)

    rows = []

    def case(name, action, expected):
        try:
            actual = action()
            ok = bool(actual)
            rows.append({'name': name, 'expected': expected,
                         'result': 'PASS' if ok else 'FAIL',
                         'detail': '' if ok else 'Unexpected status or content'})
        except Exception as exc:
            rows.append({'name': name, 'expected': expected,
                         'result': 'FAIL', 'detail': repr(exc)[:240]})

    def exact(path, status, body):
        got_status, got_body, _ = request(path)
        return (got_status, got_body) == (status, body)

    def denied(path, allowed=(400, 403, 404)):
        status, body, _ = request(path)
        return status in allowed and b'OUTSIDE-DATA' not in body and b'SIBLING-SECRET' not in body

    case('ping_control', lambda: exact('/ping', 200, b'pong'), '200 pong')
    case('root_index', lambda: exact('/', 200, b'root-index'), '200 root-index')
    case('subdir_index', lambda: exact('/sub/', 200, b'sub-index'), '200 sub-index')
    case('ordinary_file', lambda: exact('/ok.txt', 200, b'root-ok'), '200')
    case('nested_file', lambda: exact('/sub/inside.txt', 200, b'nested-ok'), '200')
    case('percent_space', lambda: exact('/sp%20ace.txt', 200, b'space-ok'), '200')
    case('decode_once', lambda: exact('/pct%252f.txt', 200, b'encoded-once'), '200')
    case('file_not_found', lambda: denied('/absent'), '404')
    case('traversal_literal', lambda: denied('/../outside-secret.txt'), 'deny')
    case('traversal_encoded', lambda: denied('/%2e%2e/outside-secret.txt'), 'deny')
    case('traversal_nested', lambda: denied('/sub/../../outside-secret.txt'), 'deny')
    case('traversal_encoded_slash', lambda: denied('/sub%2f..%2fsecret'), 'deny')
    case('traversal_double_encoded', lambda: denied('/%252e%252e/outside-secret.txt'), 'deny')
    case('sibling_prefix', lambda: denied('/../public-backup/secret.txt'), 'deny')
    case('absolute_separator', lambda: denied('/%2fetc/passwd'), 'deny')
    case('nul_rejected', lambda: denied('/ok%00.txt'), 'deny')
    case('bad_percent', lambda: denied('/abc%GG'), 'deny')
    case('symlink_file', lambda: denied('/out-file'), 'deny')
    case('symlink_directory', lambda: denied('/out-dir/secret.txt'), 'deny')
    case('broken_symlink', lambda: denied('/broken'), 'deny')
    case('symlink_cycle', lambda: denied('/cycle/ok.txt'), 'deny')
    case('non_regular_fifo', lambda: denied('/fifo'), 'deny (must not block)')
    case('other_read_permission', lambda: denied('/private.txt', (403,)), '403')

    def cached():
        first_status, first_body, first_headers = request('/ok.txt')
        etag = first_headers.get('ETag') or first_headers.get('etag')
        if first_status != 200 or first_body != b'root-ok' or not etag:
            return False
        second_status, _, _ = request('/ok.txt', {'If-None-Match': etag})
        return second_status == 304
    case('small_etag_304', cached, '200 then 304')

    def large_file():
        status, body, headers = request('/large.bin')
        return (status == 200 and body == large_body and
                int(headers.get('Content-Length', headers.get('content-length', -1))) == len(large_body))
    case('streaming_10mb', large_file, '200 / 10,000,000 bytes')

    # Replace the pathname atomically between a regular file and a symlink.
    # Requests may see a 200 inside file or a refusal, never outside content.
    race = root / 'raced.txt'
    race.write_bytes(b'inside-only')
    stop = threading.Event()

    def replace_loop():
        while not stop.is_set():
            tmp = root / 'raced-tmp'
            try:
                tmp.symlink_to(outside)
                os.replace(tmp, race)
                tmp.write_bytes(b'inside-only')
                os.replace(tmp, race)
            except FileExistsError:
                try:
                    tmp.unlink()
                except FileNotFoundError:
                    pass

    def race_never_leaks():
        thread = threading.Thread(target=replace_loop, daemon=True)
        thread.start()
        valid = True
        try:
            for _ in range(100):
                status, body, _ = request('/raced.txt')
                if status == 200 and body != b'inside-only':
                    valid = False
                if status not in (200, 403, 404):
                    valid = False
        finally:
            stop.set()
            thread.join(timeout=5)
        return valid
    case('atomic_symlink_swap', race_never_leaks, 'no outside bytes in 100 requests')

    def fd_recovery():
        before = len(os.listdir(f'/proc/{pid}/fd'))
        for _ in range(40):
            request('/out-file')
            request('/ok.txt')
        after = len(os.listdir(f'/proc/{pid}/fd'))
        return after <= before + 4
    case('fd_recovery', fd_recovery, 'FD count remains stable')
    case('post_probe_ping', lambda: exact('/ping', 200, b'pong'), '200 pong')

    passed = sum(row['result'] == 'PASS' for row in rows)
    result = {'mode': mode, 'captured_utc': datetime.now(timezone.utc).isoformat(),
              'passed': passed, 'total': len(rows), 'results': rows}
    out.mkdir(parents=True, exist_ok=True)
    (out / f'step13-{mode}.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'Step 13 {mode}: {passed}/{len(rows)} PASS')
    for row in rows:
        if row['result'] != 'PASS':
            print('FAIL:', row['name'], row['detail'])
    return 0 if passed == len(rows) else 1


if __name__ == '__main__':
    sys.exit(main())
