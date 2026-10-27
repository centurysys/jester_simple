#!/usr/bin/env python3
"""Step 11 multipart HTTP regression: loopback and standard library only."""
from __future__ import annotations
import http.client
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

HOST, PORT = '127.0.0.1', 5491


def request(path: str, data: bytes = b'', ct: str = '', method: str = 'POST'):
    conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
    try:
        headers = {'Connection': 'close'}
        if ct:
            headers['Content-Type'] = ct
        conn.request(method, path, body=data, headers=headers)
        response = conn.getresponse()
        raw = response.read(200000)
        return response.status, raw.decode('utf-8', 'replace')
    finally:
        conn.close()


def part(name: str, value: bytes, *, filename: str = '', extras: bytes = b''):
    disp = f'Content-Disposition: form-data; name="{name}"'
    if filename:
        disp += f'; filename="{filename}"'
    return disp.encode() + b'\r\n' + extras + b'\r\n' + value


def payload(boundary: str, chunks: list[bytes]) -> bytes:
    return b''.join(b'--' + boundary.encode() + b'\r\n' + chunk + b'\r\n'
                    for chunk in chunks) + b'--' + boundary.encode() + b'--\r\n'


def main() -> int:
    out, mode = Path(sys.argv[1]), sys.argv[2]
    rows: list[dict] = []
    ct = 'multipart/form-data; boundary=abc'
    basic = payload('abc', [part('name', b'hello')])
    good = {'name': {'body': 'hello', 'filename': '', 'contentType': ''}}

    def check(name: str, body: bytes, content_type: str, status: int,
              expected: object = None, path: str = '/upload'):
        try:
            code, text = request(path, body, content_type,
                                 method='GET' if path == '/ping' else 'POST')
            parsed = json.loads(text) if status == 200 and path == '/upload' and code == 200 else text
            ok = code == status and (expected is None or parsed == expected)
            if status == 400:
                ok = ok and 'Traceback' not in text and 'Content-Disposition' not in text
            rows.append({'name': name, 'status': code, 'expected': status,
                         'result': 'PASS' if ok else 'FAIL',
                         'detail': '' if ok else repr(parsed)[:400]})
        except Exception as exc:
            rows.append({'name': name, 'status': None, 'expected': status,
                         'result': 'FAIL', 'detail': repr(exc)})

    check('normal_upload', basic, ct, 200, good)
    check('quoted_boundary', payload('a:b?c', [part('name', b'hello')]),
          'MULTIPART/FORM-DATA; charset=UTF-8; boundary="a:b?c"', 200, good)
    check('boundary_case_insensitive', basic,
          'MULTIPART/FORM-DATA; BOUNDARY=abc', 200, good)
    check('filename_and_content_type', payload('abc', [part('file', b'hello',
          filename='test.txt', extras=b'Content-Type: text/plain\r\n')]),
          ct, 200, {'file': {'body': 'hello', 'filename': 'test.txt',
                            'contentType': 'text/plain'}})
    check('binary_and_lookalike_delimiter', payload('abc',
          [part('name', b'before\x00\r\n--abcNOTREAL\r\nafter')]), ct, 200,
          {'name': {'body': 'before\x00\r\n--abcNOTREAL\r\nafter',
                    'filename': '', 'contentType': ''}})
    check('duplicate_name_last_wins', payload('abc',
          [part('name', b'one'), part('name', b'two')]), ct, 200,
          {'name': {'body': 'two', 'filename': '', 'contentType': ''}})
    check('empty_part', payload('abc', [part('name', b'')]), ct, 200,
          {'name': {'body': '', 'filename': '', 'contentType': ''}})
    check('empty_multipart', b'--abc--\r\n', ct, 200, {})
    check('preamble_and_epilogue', b'pre\r\n' + basic + b'post', ct, 200, good)
    check('no_boundary_parameter', basic, 'multipart/form-data', 400)
    check('empty_boundary_parameter', basic, 'multipart/form-data; boundary=', 400)
    check('duplicate_boundary_parameter', basic,
          'multipart/form-data; boundary=abc; BOUNDARY=abc', 400)
    check('wrong_boundary', basic, 'multipart/form-data; boundary=wrong', 400)
    check('missing_closing_boundary', basic[:-9], ct, 400)
    check('truncated_delimiter', basic[:-4], ct, 400)
    check('bad_part_header', b'--abc\r\nInvalidHeader\r\n\r\nx\r\n--abc--\r\n',
          ct, 400)
    check('missing_disposition', b'--abc\r\nX-Test: a\r\n\r\nx\r\n--abc--\r\n',
          ct, 400)
    check('missing_name', b'--abc\r\nContent-Disposition: form-data\r\n'
          b'\r\nx\r\n--abc--\r\n', ct, 400)
    check('duplicate_disposition', b'--abc\r\nContent-Disposition: form-data; '
          b'name=x\r\nContent-Disposition: form-data; name=x\r\n\r\ny\r\n'
          b'--abc--\r\n', ct, 400)
    check('header_count_exceeded', b'--abc\r\nContent-Disposition: '
          b'form-data; name=x\r\n' + b'X-Test: a\r\n' * 65 +
          b'\r\nx\r\n--abc--\r\n', ct, 400)
    check('header_bytes_exceeded', b'--abc\r\nContent-Disposition: '
          b'form-data; name=x\r\nX-Fill: ' + b'a' * 8200 +
          b'\r\n\r\nx\r\n--abc--\r\n', ct, 400)
    check('part_count_exceeded', payload('abc', [part('x', b'v')] * 129), ct, 400)
    check('bad_multipart_even_when_unused', basic[:-9], ct, 400,
          path='/ignored')
    check('normal_when_route_ignores_form', basic, ct, 200, 'ignored',
          path='/ignored')
    check('application_nonmultipart', b'arbitrary',
          'application/octet-stream', 200, {})
    # Whole-body maxBody applies before multipart parsing.
    check('body_over_64KiB', payload('abc', [part('name', b'a' * 65536)]),
          ct, 413)
    check('post_probe_ping', b'', '', 200, 'pong', path='/ping')

    out.mkdir(parents=True, exist_ok=True)
    passed = sum(r['result'] == 'PASS' for r in rows)
    document = {'mode': mode, 'captured_utc': datetime.now(timezone.utc).isoformat(),
                'passed': passed, 'total': len(rows), 'results': rows}
    (out / f'step11-{mode}.json').write_text(json.dumps(document, ensure_ascii=False,
                                                          indent=2) + '\n')
    print(f'Step 11 {mode}: {passed}/{len(rows)} PASS')
    for row in rows:
        if row['result'] == 'FAIL':
            print('FAIL:', row['name'], row['status'], row['detail'])
    return 0 if passed == len(rows) else 1


if __name__ == '__main__':
    sys.exit(main())
