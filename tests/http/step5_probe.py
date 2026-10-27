#!/usr/bin/env python3
"""Step 5: deterministic localhost-only HTTP framing acceptance tests.

The server is the Jester Simple Step 4 fixture running on 127.0.0.1:5481.
The client intentionally creates malformed HTTP; never point it at a remote host.
"""
from __future__ import annotations

import json
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from step4_probe import HOST, PORT, MAX_BODY, make_request, chunked, send_probe, recv_response


def observe(name: str, payload: bytes, expected: int, *, half_close: bool = False) -> dict:
    result = send_probe(name, 'step5', payload, shutdown_write=half_close)
    result['expected'] = expected
    result['ok'] = result.get('status') == expected
    return result


def check_close(name: str, payload: bytes, expected: int, *, half_close: bool = False) -> dict:
    raw = bytearray()
    closed = False
    with socket.create_connection((HOST, PORT), timeout=2) as sock:
        sock.settimeout(2)
        sock.sendall(payload)
        if half_close:
            sock.shutdown(socket.SHUT_WR)
        try:
            while len(raw) < 256 * 1024:
                buf = sock.recv(4096)
                if not buf:
                    closed = True
                    break
                raw.extend(buf)
        except (ConnectionResetError, BrokenPipeError):
            closed = True
        except socket.timeout:
            pass
    line = raw.split(b'\r\n', 1)[0].decode('latin-1', 'replace')
    parts = line.split(' ', 2)
    code = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else None
    count = raw.count(b'HTTP/1.1 ')
    return dict(name=name, status=code, expected=expected, closed=closed,
                responses=count, ok=(code == expected and closed and count == 1))


def split_write() -> dict:
    headers = make_request('POST', '/step4/body', ['Transfer-Encoding: chunked'])
    body = chunked([b'abcde', b'xyz'])
    payload = headers + body
    with socket.create_connection((HOST, PORT), timeout=2) as sock:
        sock.settimeout(2)
        for off in range(0, len(payload), 3):
            sock.sendall(payload[off:off + 3])
            time.sleep(0.001)
        response = recv_response(sock)
    ok = response.get('status') == 200 and response.get('body_sample') == '8'
    return dict(name='split_tcp_chunked', ok=ok, response=response)


def persistent_chunked() -> dict:
    first = (b'POST /step4/body HTTP/1.1\r\n'
             b'Host: 127.0.0.1:5481\r\n'
             b'Transfer-Encoding: chunked\r\n\r\n') + chunked([b'abc'])
    second = make_request('GET', '/step4/ping', ['Connection: close'])
    raw = bytearray()
    with socket.create_connection((HOST, PORT), timeout=2) as sock:
        sock.settimeout(2)
        sock.sendall(first + second)
        try:
            while len(raw) < 8192:
                data = sock.recv(4096)
                if not data:
                    break
                raw.extend(data)
        except socket.timeout:
            pass
    ok = raw.count(b'HTTP/1.1 200 ') == 2 and b'pong' in raw
    return dict(name='valid_chunked_then_keepalive_get', ok=ok,
                status_lines=[x.decode('latin-1', 'replace')
                              for x in raw.split(b'\r\n') if x.startswith(b'HTTP/1.1')])


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else 'docs/modernization/step5-results')
    out.mkdir(parents=True, exist_ok=True)
    cases = []
    add = cases.append
    req = lambda headers, body=b'': make_request('POST', '/step4/body', headers, body)

    add(observe('get_control', make_request('GET', '/step4/ping', []), 200))
    add(observe('cl_small', req(['Content-Length: 4'], b'DATA'), 200))
    for n in (MAX_BODY - 1, MAX_BODY, MAX_BODY + 1):
        body = b'A' * n if n <= MAX_BODY else b''
        add(observe(f'cl_{n}', req([f'Content-Length: {n}'], body),
                    200 if n <= MAX_BODY else 413))
        add(observe(f'chunked_{n}', req(['Transfer-Encoding: chunked'],
                    chunked([b'B' * n])), 200 if n <= MAX_BODY else 413))

    add(observe('chunked_multichunk_max', req(['Transfer-Encoding: chunked'],
                chunked([b'C' * 12345, b'D' * (MAX_BODY - 12345)])), 200))
    add(observe('chunked_multichunk_over', req(['Transfer-Encoding: chunked'],
                chunked([b'C' * 12345, b'D' * (MAX_BODY - 12344)])), 413))
    add(observe('chunked_uppercase', req(['Transfer-Encoding: CHUNKED'],
                chunked([b'abc'])), 200))
    add(observe('chunked_valid_trailer', req(['Transfer-Encoding: chunked'],
                b'3\r\nabc\r\n0\r\nX-Trace: ok\r\n\r\n'), 200))
    add(check_close('chunk_extension_unsupported', req(['Transfer-Encoding: chunked'],
                    b'3;foo=bar\r\nabc\r\n0\r\n\r\n'), 400))

    reject = [
        ('te_and_cl', ['Content-Length: 3', 'Transfer-Encoding: chunked'], b'3\r\nabc\r\n0\r\n\r\n'),
        ('cl_conflicting', ['Content-Length: 3', 'Content-Length: 4'], b'abcd'),
        ('cl_same_duplicate', ['Content-Length: 3', 'Content-Length: 3'], b'abc'),
        ('cl_duplicate_mixed_case', ['Content-Length: 3', 'content-length: 3'], b'abc'),
        ('cl_list', ['Content-Length: 3, 3'], b''),
        ('cl_negative', ['Content-Length: -1'], b''),
        ('cl_plus_sign', ['Content-Length: +3'], b''),
        ('cl_partial_digits', ['Content-Length: 3junk'], b''),
        ('cl_overflow', ['Content-Length: 999999999999999999999999999999999'], b''),
        ('te_unsupported', ['Transfer-Encoding: gzip, chunked'], b''),
        ('te_duplicate', ['Transfer-Encoding: chunked', 'Transfer-Encoding: chunked'], b''),
    ]
    for name, headers, body in reject:
        add(check_close(name, req(headers, body), 400))
    add(check_close('bad_chunk_size', req(['Transfer-Encoding: chunked'], b'ZZ\r\n'),
                    400))
    add(check_close('missing_zero_chunk', req(['Transfer-Encoding: chunked'],
                    chunked([b'abc'], terminal=False)), 400, half_close=True))
    add(check_close('short_chunk_body', req(['Transfer-Encoding: chunked'],
                    b'5\r\nabc'), 400, half_close=True))
    add(check_close('missing_chunk_crlf', req(['Transfer-Encoding: chunked'],
                    b'3\r\nabcZZ0\r\n\r\n'), 400))
    add(check_close('bad_trailer', req(['Transfer-Encoding: chunked'],
                    b'0\r\nnot-a-header\r\n\r\n'), 400))
    # A corrupt first request must never be followed by an accepted GET.
    invalid = req(['Content-Length: 3', 'Content-Length: 4'], b'abcd')
    add(check_close('bad_cl_with_pipelined_get', invalid +
                    make_request('GET', '/step4/ping', []), 400))
    add(check_close('expect_above_limit', req(
                    [f'Content-Length: {MAX_BODY + 1}', 'Expect: 100-continue']), 413))
    add(split_write())
    add(persistent_chunked())
    add(observe('post_probe_ping', make_request('GET', '/step4/ping', []), 200))

    results = dict(utc=datetime.now(timezone.utc).isoformat(),
                   total=len(cases), pass_count=sum(bool(c['ok']) for c in cases),
                   tests=cases)
    (out / 'observations.json').write_text(json.dumps(results, indent=2) + '\n')
    rows = ['# Step 5 HTTP transport regression', '',
            'This is a localhost-only acceptance test of HTTP framing.', '',
            f"Passed: {results['pass_count']} / {results['total']}", '',
            '| Test | HTTP | Expected | Result |', '| --- | ---: | ---: | --- |']
    for c in cases:
        rows.append(f"| {c['name']} | {c.get('status', 'n/a')} | "
                    f"{c.get('expected', 'n/a')} | {'PASS' if c['ok'] else 'FAIL'} |")
    (out / 'REPORT.md').write_text('\n'.join(rows) + '\n')
    print('\n'.join(rows))
    return 0 if results['pass_count'] == results['total'] else 1


if __name__ == '__main__':
    sys.exit(main())
