#!/usr/bin/env python3
"""Step 14 static response correctness, metadata validators, bounded memory."""
from __future__ import annotations

import hashlib
import http.client
import json
import os
import socket
import sys
from datetime import datetime, timezone
from pathlib import Path

HOST, PORT = '127.0.0.1', 5495


def request(path: str, method='GET', headers=None):
    conn = http.client.HTTPConnection(HOST, PORT, timeout=40)
    try:
        conn.request(method, path, headers=headers or {})
        response = conn.getresponse()
        status = response.status
        fields = {key.lower(): val for key, val in response.getheaders()}
        body = response.read()
        return status, fields, body
    finally:
        conn.close()


def raw_request(path: str, method: str, headers=None):
    raw = f'{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n'
    for key, value in (headers or {}).items():
        raw += f'{key}: {value}\r\n'
    raw += '\r\n'
    with socket.create_connection((HOST, PORT), timeout=10) as sock:
        sock.settimeout(10)
        sock.sendall(raw.encode('ascii'))
        packets = []
        while True:
            packet = sock.recv(65536)
            if not packet:
                break
            packets.append(packet)
    joined = b''.join(packets)
    if b'\r\n\r\n' not in joined:
        raise AssertionError('Incomplete HTTP response headers')
    return joined.split(b'\r\n\r\n', 1)


def file_bytes(path: Path, size: int, seed: bytes):
    with path.open('wb') as f:
        total = 0
        block = (seed * (65536 // len(seed) + 1))[:65536]
        while total < size:
            length = min(len(block), size - total)
            f.write(block[:length])
            total += length
    path.chmod(0o644)


def checksum(data: bytes):
    return hashlib.sha256(data).digest()


def main():
    out, mode, root, pid = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), int(sys.argv[4])
    outside = root.parent / 'explicit-asset.txt'
    root.mkdir(parents=True, exist_ok=True)
    outside.write_bytes(b'explicit-file')
    outside.chmod(0o644)
    (root / 'index.html').write_bytes(b'step14-index')
    (root / 'empty.txt').write_bytes(b'')
    (root / 'tiny.txt').write_bytes(b'hello world')
    (root / 'updated.txt').write_bytes(b'original')
    (root / 'sub').mkdir(exist_ok=True)
    (root / 'sub' / 'index.htm').write_bytes(b'nested-index')

    sizes = {
        'block': 16384, 'block-plus': 16385,
        'below-10m': 9_999_999, 'at-10m': 10_000_000,
        'above-10m': 10_000_001, 'large-32m': 32 * 1024 * 1024,
    }
    for name, size in sizes.items():
        file_bytes(root / f'{name}.bin', size, f'Jester14-{name}!'.encode())

    rows = []

    def case(name, fn, expectation):
        try:
            good = bool(fn())
            detail = '' if good else 'Unexpected HTTP status, headers or body'
        except Exception as exc:
            good, detail = False, repr(exc)[:240]
        rows.append({'name': name, 'expected': expectation,
                     'result': 'PASS' if good else 'FAIL', 'detail': detail})

    def get_exact(path, data):
        code, fields, body = request(path)
        return (code == 200 and body == data and
                fields.get('content-length') == str(len(data)) and
                fields.get('etag', '').startswith('W/"'))

    def check_fixture(name):
        path = root / f'{name}.bin'
        code, fields, body = request('/' + path.name)
        return (code == 200 and fields.get('content-length') == str(path.stat().st_size)
                and checksum(body) == checksum(path.read_bytes())
                and len(body) == path.stat().st_size and fields.get('etag', '').startswith('W/"'))

    case('route_control', lambda: request('/ping')[::2] == (200, b'pong'), '200 pong')
    case('root_index', lambda: get_exact('/', b'step14-index'), '200 root-index')
    case('subdir_index', lambda: get_exact('/sub/', b'nested-index'), '200')
    case('empty_file', lambda: get_exact('/empty.txt', b''), '200, 0 bytes')
    case('tiny_file', lambda: get_exact('/tiny.txt', b'hello world'), '200, 11 bytes')
    for name in sizes:
        case('file_' + name.replace('-', '_'), lambda n=name: check_fixture(n),
             '200, exact Content-Length and SHA256')

    def head_correct(path):
        get_code, get_headers, _ = request(path)
        head_code, head_headers, head_body = request(path, 'HEAD')
        return (get_code == head_code == 200 and head_body == b'' and
                get_headers.get('etag') == head_headers.get('etag') and
                get_headers.get('content-type') == head_headers.get('content-type') and
                get_headers.get('content-length') == head_headers.get('content-length'))

    for path in ('/tiny.txt', '/empty.txt', '/index.html', '/at-10m.bin', '/large-32m.bin'):
        case('head_' + path.strip('/').replace('.', '_').replace('-', '_'),
             lambda p=path: head_correct(p), 'HEAD metadata matches GET, no body')

    def raw_head_no_body(path):
        headers, body = raw_request(path, 'HEAD')
        return b' 200 ' in headers.split(b'\r\n', 1)[0] and body == b''

    case('head_raw_no_bytes_small', lambda: raw_head_no_body('/tiny.txt'), 'no wire body')
    case('head_raw_no_bytes_large', lambda: raw_head_no_body('/large-32m.bin'), 'no wire body')

    code, meta, _ = request('/tiny.txt')
    etag = meta.get('etag', '')
    bare = etag[2:] if etag.startswith('W/') else etag

    def conditional(method, validator, want):
        code, fields, body = request('/tiny.txt', method, {'If-None-Match': validator})
        if code != want:
            return False
        if want == 304:
            return body == b'' and fields.get('etag') == etag and 'content-length' not in fields
        return code == 200 and (body == b'' if method == 'HEAD' else body == b'hello world')

    case('etag_weak_match', lambda: conditional('GET', etag, 304), '304')
    case('etag_strong_comparison', lambda: conditional('GET', bare, 304), '304')
    case('etag_wildcard', lambda: conditional('GET', '*', 304), '304')
    case('etag_list', lambda: conditional('GET', f'"different", {etag}', 304), '304')
    case('etag_mismatch', lambda: conditional('GET', '"wrong"', 200), '200')
    case('etag_malformed', lambda: conditional('GET', 'wrong', 200), '200')
    case('head_etag_304', lambda: conditional('HEAD', etag, 304), '304')
    case('head_etag_mismatch', lambda: conditional('HEAD', '"wrong"', 200), '200 no body')

    def raw_304():
        hdr, body = raw_request('/tiny.txt', 'GET', {'If-None-Match': etag})
        return b' 304 ' in hdr.split(b'\r\n', 1)[0] and body == b'' and b'content-length:' not in hdr.lower()
    case('raw_304_no_body', raw_304, 'no wire body, no Content-Length')

    def etag_replace():
        old_status, old_hdr, _ = request('/updated.txt')
        new_path = root / 'updated.tmp'
        new_path.write_bytes(b'replaced')  # Exactly the old representation length.
        new_path.chmod(0o644)
        os.replace(new_path, root / 'updated.txt')
        new_status, new_hdr, new_data = request('/updated.txt', headers={
            'If-None-Match': old_hdr['etag']})
        return (old_status == new_status == 200 and new_data == b'replaced' and
                new_hdr.get('etag') != old_hdr.get('etag'))
    case('atomic_replace_etag_changed', etag_replace, '200 with a new validator')

    def explicit_file():
        code, fields, body = request('/explicit')
        return code == 200 and body == b'explicit-file' and fields.get('content-length') == '13'
    case('explicit_sendfile', explicit_file, '200, 13 bytes')

    def explicit_conditional():
        code, fields, body = request('/explicit')
        if code != 200 or body != b'explicit-file':
            return False
        cached_code, cached_fields, cached_body = request('/explicit', headers={
            'If-None-Match': fields['etag']})
        return (cached_code == 304 and cached_body == b'' and
                cached_fields.get('etag') == fields['etag'])
    case('explicit_sendfile_304', explicit_conditional, '304 without route exception')

    def range_ignored():
        status, _, body = request('/tiny.txt', headers={'Range': 'bytes=0-1'})
        return status == 200 and body == b'hello world'
    case('range_ignored_with_full_200', range_ignored, '200 full body (ranges not supported)')

    def no_fd_leak():
        before = len(os.listdir(f'/proc/{pid}/fd'))
        for _ in range(40):
            request('/tiny.txt')
            request('/large-32m.bin', method='HEAD')
        after = len(os.listdir(f'/proc/{pid}/fd'))
        return after <= before + 4
    case('fd_recovery', no_fd_leak, 'FD count stable')

    def hwm_kib():
        status = Path(f'/proc/{pid}/status').read_text()
        return int(next(line.split()[1] for line in status.splitlines()
                        if line.startswith('VmHWM:')))

    # Warm up the server first. A streamed 32 MiB response must not add a
    # whole-file allocation to its peak resident memory.
    request('/tiny.txt')
    before_peak = hwm_kib()

    def rss_streaming():
        code, _, body = request('/large-32m.bin')
        return code == 200 and len(body) == 32 * 1024 * 1024 and hwm_kib() - before_peak < 12 * 1024
    case('bounded_peak_rss_32m', rss_streaming, 'peak RSS increase below 12 MiB')
    case('post_probe_control', lambda: request('/ping')[::2] == (200, b'pong'), '200 pong')

    passed = sum(row['result'] == 'PASS' for row in rows)
    result = {'mode': mode, 'captured_utc': datetime.now(timezone.utc).isoformat(),
              'passed': passed, 'total': len(rows), 'results': rows,
              'server_vm_hwm_kib': hwm_kib()}
    out.mkdir(parents=True, exist_ok=True)
    (out / f'step14-{mode}.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'Step 14 {mode}: {passed}/{len(rows)} PASS')
    for row in rows:
        if row['result'] != 'PASS':
            print('FAIL:', row['name'], row['detail'])
    return 0 if passed == len(rows) else 1


if __name__ == '__main__':
    sys.exit(main())
