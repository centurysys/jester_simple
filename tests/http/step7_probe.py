#!/usr/bin/env python3
"""Step 7 acceptance using only Python stdlib, localhost port 5483."""
from __future__ import annotations

import http.client
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

HOST, PORT = '127.0.0.1', 5483
SECRET_MARKERS = (
    'SYNC_PRIVATE_TOKEN', 'ASYNC_PRIVATE_TOKEN', 'HANDLER_PRIVATE_TOKEN',
    'SYNC_FAST_PATH_SECRET', 'original handler detail', 'script name:', 'ValueError',
    'Stack trace:', 'Traceback', '/home/', 'jestersimple.nim(',
)


def get(path: str, port: int = PORT) -> tuple[int, str]:
    conn = http.client.HTTPConnection(HOST, port, timeout=3)
    try:
        conn.request('GET', path, headers={'Connection': 'close'})
        response = conn.getresponse()
        return response.status, response.read(65536).decode('utf-8', 'replace')
    finally:
        conn.close()


def main() -> int:
    out = Path(sys.argv[1]); mode = sys.argv[2]
    rows: list[dict] = []

    def test(name: str, path: str, expected: int, body: str | None = None,
             generic: bool = False, port: int = PORT) -> None:
        try:
            status, received = get(path, port)
            ok = status == expected
            if body is not None:
                ok = ok and received == body
            if generic:
                ok = ok and not any(s in received for s in SECRET_MARKERS)
                ok = ok and '<script>' not in received
                ok = ok and '<img' not in received
            rows.append({'test': name, 'status': status, 'expected': expected,
                         'result': 'PASS' if ok else 'FAIL',
                         'detail': received[:200] if not ok else ''})
        except Exception as ex:
            rows.append({'test': name, 'status': None, 'expected': expected,
                         'result': 'FAIL', 'detail': repr(ex)})

    test('ping_before', '/app/step7/ping', 200, body='pong')
    test('sync_exception', '/app/step7/sync', 500, generic=True)
    test('async_exception', '/app/step7/async', 500, generic=True)
    test('custom_exception_handler', '/app/step7/custom', 409,
         body='custom handler preserved')
    test('error_handler_raises', '/app/step7/handler-fails', 500, generic=True)
    test('custom_status_handler', '/app/step7/forbidden', 403,
         body='custom forbidden response')
    test('explicit_halt_preserved', '/app/step7/explicit', 502,
         body='explicit application response')
    test('missing_mount', '/', 404, generic=True)
    test('mount_partial_prefix', '/application/step7/ping', 404, generic=True)
    test('mount_same_prefix_noseparator', '/appstep7/ping', 404, generic=True)
    test('mount_prefix_exact', '/app', 200, body='mounted root')
    test('mount_prefix_slash', '/app/', 200, body='mounted root')
    test('unmatched_path', '/app/no-such-route', 404, generic=True)
    test('sync_fast_path_exception', '/app/step7/sync', 500,
         generic=True, port=5484)
    test('sync_server_recovery', '/app/step7/ping', 200,
         body='pong', port=5484)
    test('ping_after_exceptions', '/app/step7/ping', 200, body='pong')

    passed = sum(row['result'] == 'PASS' for row in rows)
    result = {'mode': mode, 'captured_utc': datetime.now(timezone.utc).isoformat(),
              'passed': passed, 'total': len(rows), 'results': rows}
    out.mkdir(parents=True, exist_ok=True)
    (out / f'step7-{mode}.json').write_text(
        json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    print(f'Step 7 {mode}: {passed}/{len(rows)} PASS')
    for row in rows:
        if row['result'] == 'FAIL':
            print('FAIL:', row['test'], row['status'], row['detail'])
    return 0 if passed == len(rows) else 1


if __name__ == '__main__':
    sys.exit(main())
