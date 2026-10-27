#!/usr/bin/env python3
"""Loopback HTTP response framing and Cookie checks, Python stdlib only."""
from __future__ import annotations
import http.client
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

HOST = '127.0.0.1'


def get(path: str, port: int = 5485) -> dict:
    conn = http.client.HTTPConnection(HOST, port, timeout=4)
    try:
        conn.request('GET', path, headers={'Connection': 'close'})
        response = conn.getresponse()
        data = response.read(65536).decode('utf-8', 'replace')
        return {'status': response.status, 'headers': response.getheaders(), 'body': data}
    finally:
        conn.close()


def values(result: dict, name: str) -> list[str]:
    return [v for k, v in result['headers'] if k.lower() == name.lower()]


def safe(result: dict) -> bool:
    all_headers = '\n'.join(f'{k}: {v}' for k, v in result['headers'])
    return ('Injected:' not in all_headers and 'Forged:' not in all_headers
            and 'NEVER_EXPOSE_THIS' not in result['body']
            and all('\r' not in k + v and '\n' not in k + v
                    for k, v in result['headers']))


def main() -> int:
    out, mode = Path(sys.argv[1]), sys.argv[2]
    rows = []

    def test(name: str, path: str, code: int, body: str | None = None,
             header: tuple[str, str] | None = None, cookie_count: int | None = None,
             port: int = 5485, generic: bool = False, case_unique: bool = False):
        try:
            r = get(path, port)
            ok = r['status'] == code and safe(r)
            if body is not None:
                ok = ok and r['body'] == body
            if header is not None:
                ok = ok and header[1] in values(r, header[0])
            if cookie_count is not None:
                ok = ok and len(values(r, 'Set-Cookie')) == cookie_count
            if case_unique:
                ok = ok and len(values(r, 'X-Case')) == 1 and values(r, 'X-Case') == ['new']
            if generic:
                ok = ok and '500' in r['body'] and 'NEVER_EXPOSE_THIS' not in r['body']
            rows.append({'test': name, 'status': r['status'], 'expected': code,
                         'result': 'PASS' if ok else 'FAIL',
                         'detail': str(r)[:600] if not ok else ''})
        except Exception as exc:
            rows.append({'test': name, 'status': None, 'expected': code,
                         'result': 'FAIL', 'detail': repr(exc)})

    test('control_before', '/ping', 200, 'pong')
    test('standard_header', '/normal', 200, 'ok', header=('X-Test', 'safe'))
    test('case_insensitive_setHeader_replace', '/case-replace', 200, 'case', case_unique=True)
    test('multiple_set_cookie', '/cookie', 200, 'cookies', cookie_count=2)
    test('mixed_case_set_cookie', '/cookie-mixed-case', 200, 'cookies', cookie_count=2)
    test('redirect_preserved', '/redirect', 302, '', header=('Location', '/safe'))
    for name, path in [
        ('reject_bad_field_name', '/bad-name'),
        ('reject_crlf_in_value', '/bad-value'),
        ('reject_redirect_crlf', '/bad-redirect'),
        ('reject_direct_resp_crlf', '/resp-bad'),
        ('reject_bad_content_length', '/resp-bad-length'),
        ('reject_duplicate_content_length', '/resp-duplicate-length'),
        ('reject_transfer_encoding', '/resp-transfer-encoding'),
        ('reject_bad_cookie_name', '/bad-cookie-name'),
        ('reject_cookie_value_delimiter', '/bad-cookie-value'),
        ('reject_cookie_domain_delimiter', '/bad-cookie-domain'),
        ('reject_attachment_crlf', '/bad-attachment'),
        ('reject_raw_header_crlf', '/raw-bad'),
    ]:
        test(name, path, 500, generic=True)
    test('valid_explicit_content_length', '/resp-valid-length', 200, 'hi',
         header=('Content-Length', '2'))
    test('escaped_attachment_filename', '/attachment', 200, 'attached',
         header=('Content-Disposition', 'attachment; filename="report\\"quoted\\\\file.txt"'))
    test('valid_raw_response', '/raw-valid', 200, 'hello', header=('Content-Type', 'text/plain'))
    test('single_sync_matcher_rejects_crlf', '/', 500, port=5486, generic=True)
    test('control_after', '/ping', 200, 'pong')

    passed = sum(r['result'] == 'PASS' for r in rows)
    result = {'mode': mode, 'captured_utc': datetime.now(timezone.utc).isoformat(),
              'passed': passed, 'total': len(rows), 'results': rows}
    out.mkdir(parents=True, exist_ok=True)
    (out / f'step8-{mode}.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'Step 8 {mode}: {passed}/{len(rows)} PASS')
    for r in rows:
        if r['result'] == 'FAIL':
            print('FAIL:', r['test'], r['detail'])
    return 0 if passed == len(rows) else 1

if __name__ == '__main__':
    sys.exit(main())
