#!/usr/bin/env python3
"""Step 10: loopback-only HTTP query/form decoding regression (stdlib)."""
from __future__ import annotations

import http.client
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

HOST, PORT = '127.0.0.1', 5490


def request(method: str, path: str, body: str = '', ctype: str = '') -> tuple[int, str]:
    conn = http.client.HTTPConnection(HOST, PORT, timeout=4)
    try:
        headers = {'Connection': 'close'}
        if ctype:
            headers['Content-Type'] = ctype
        content = body.encode('utf-8') if body else None
        conn.request(method, path, body=content, headers=headers)
        response = conn.getresponse()
        return response.status, response.read(131072).decode('utf-8', 'replace')
    finally:
        conn.close()


def main() -> int:
    out, mode = Path(sys.argv[1]), sys.argv[2]
    rows = []
    FORM = 'application/x-www-form-urlencoded'

    def check(name: str, path: str, code: int, expected: object = None,
              method: str = 'GET', body: str = '', ctype: str = '',
              as_json: bool = True):
        try:
            status, payload = request(method, path, body, ctype)
            actual = json.loads(payload) if as_json and status == 200 else payload
            ok = status == code and (expected is None or actual == expected)
            rows.append({'name': name, 'status': status, 'expected_status': code,
                         'result': 'PASS' if ok else 'FAIL',
                         'detail': '' if ok else repr(actual)[:400]})
        except Exception as exc:
            rows.append({'name': name, 'status': None, 'expected_status': code,
                         'result': 'FAIL', 'detail': repr(exc)})

    check('ping_before', '/ping', 200, 'pong', as_json=False)
    check('single_decode_percent25', '/single?v=%252F', 200, {'v': '%2F'})
    check('single_decode_percent2525', '/single?v=%2525', 200, {'v': '%25'})
    check('encoded_slash_in_query', '/single?v=a%2Fb', 200, {'v': 'a/b'})
    check('plus_and_literal_plus', '/single?v=a+b&w=a%2Bb', 200,
          {'v': 'a b', 'w': 'a+b'})
    check('literal_equals_and_ampersand', '/single?v=a%3Db%26c', 200,
          {'v': 'a=b&c'})
    check('single_duplicate_last_wins', '/single?v=1&v=2', 200, {'v': '2'})
    check('multi_duplicate_order', '/multi?v=1&v=2&v=', 200,
          {'v': ['1', '2', '']})
    check('empty_keys_and_empty_values', '/multi?=x&flag&tail=&a=1&&a=2', 200,
          {'': ['x'], 'flag': [''], 'tail': [''], 'a': ['1', '2']})
    check('case_insensitive_escape', '/single?v=%2f%2F%3d%3D', 200,
          {'v': '//=='})
    check('unicode_utf8', '/single?%E5%90%8D=%E6%97%A5%E6%9C%AC', 200,
          {'名': '日本'})
    check('fragment_not_query', '/single?v=1#fragment', 200, {'v': '1'})
    check('pattern_stays_escaped', '/path/a%252Fb', 200,
          {'item': ['a%252Fb']})
    check('pattern_escaped_slash_not_segment', '/path/a%2Fb', 200,
          {'item': ['a%2Fb']})
    check('pattern_plus_is_literal', '/path/a+b', 200, {'item': ['a+b']})
    check('pattern_plus_query_decoded', '/path/a%2Fb?v=a+b', 200,
          {'item': ['a%2Fb'], 'v': ['a b']})
    check('raw_path_unchanged', '/raw/a%252Fb', 200, '/raw/a%252Fb', as_json=False)
    check('form_exact_ctype_single', '/single?v=fromquery', 200,
          {'v': '%2F', 'w': 'ok'}, 'POST', 'v=%252F&w=ok', FORM)
    check('form_case_insensitive_ctype', '/multi?v=a', 200,
          {'v': ['a', '%25', 'b'], 'w': ['日本']}, 'POST',
          'v=%2525&v=b&w=%E6%97%A5%E6%9C%AC',
          'APPLICATION/X-WWW-FORM-URLENCODED; charset=UTF-8')
    check('form_duplicate_merges', '/multi?v=q&v=q2', 200,
          {'v': ['q', 'q2', 'form', '']}, 'POST', 'v=form&v=', FORM)
    check('form_non_matching_ctype', '/single?v=q', 200,
          {'v': 'q'}, 'POST', 'v=malicious', FORM + '-extra')
    check('form_text_plain_unchanged', '/single?v=q', 200,
          {'v': 'q'}, 'POST', 'v=%', 'text/plain')
    check('form_encoded_separator_key', '/multi', 200,
          {'a&b': ['1=2']}, 'POST', 'a%26b=1%3D2', FORM)
    check('raw_query_not_redecoded', '/single?x=%25252F', 200,
          {'x': '%252F'})
    for name, path in [
        ('reject_short_percent', '/single?v=%'),
        ('reject_one_digit_percent', '/single?v=%2'),
        ('reject_invalid_percent', '/single?v=%GG'),
        ('reject_invalid_key_percent', '/multi?%ZZ=1'),
        ('reject_encoded_nul', '/single?v=%00'),
        ('reject_encoding_even_when_route_ignores_query', '/ping?v=%GG'),
    ]:
        check(name, path, 400, as_json=False)
    check('reject_invalid_form_percent', '/single', 400, method='POST',
          body='v=%2', ctype=FORM, as_json=False)
    check('reject_nul_form', '/multi', 400, method='POST',
          body='v=%00', ctype=FORM, as_json=False)
    check('valid_after_malformed', '/ping', 200, 'pong', as_json=False)

    out.mkdir(parents=True, exist_ok=True)
    passed = sum(t['result'] == 'PASS' for t in rows)
    report = {'mode': mode, 'captured_utc': datetime.now(timezone.utc).isoformat(),
              'passed': passed, 'total': len(rows), 'results': rows}
    (out / f'step10-{mode}.json').write_text(json.dumps(report, indent=2,
                                                     ensure_ascii=False) + '\n')
    print(f'Step 10 {mode}: {passed}/{len(rows)} PASS')
    for item in rows:
        if item['result'] == 'FAIL':
            print('FAIL:', item['name'], item['status'], item['detail'])
    return 0 if passed == len(rows) else 1


if __name__ == '__main__':
    sys.exit(main())
