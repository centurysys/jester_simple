#!/usr/bin/env python3
"""Compare sync one/multiple and async matcher HTTP semantics on loopback."""
from __future__ import annotations

import http.client
import json
import statistics
import sys
import time
from pathlib import Path

HOST = '127.0.0.1'
PORTS = {'sync_single': 5496, 'sync_multiple': 5497, 'async_single': 5498}
# The representation is byte-for-byte comparable between matcher shapes.
CASES = [
    ('simple_200', 'GET', '/ok', 200, b'hello'),
    ('empty_403_custom', 'GET', '/empty403', 403, b'custom forbidden'),
    ('empty_500_custom', 'GET', '/empty500', 500, b'custom server error'),
    ('empty_404_default', 'GET', '/empty404', 404, None),
    ('halt_403_explicit', 'GET', '/halt403', 403, b'explicit forbidden'),
    ('halt_500_explicit', 'GET', '/halt500', 500, b'explicit failure'),
    ('pass_to_next_route', 'GET', '/pass', 200, b'passed'),
    ('redirect_303', 'GET', '/redirect', 303, b''),
    ('raw_send', 'GET', '/raw', 200, b'raw-bytes'),
    ('custom_exception_handler', 'GET', '/exception', 409, b'custom exception'),
    ('handler_exception_fallback', 'GET', '/handler-fails', 500, None),
    ('empty_204', 'GET', '/no-content', 204, b''),
    ('static_fallback', 'GET', '/static.txt', 200, b'step15-static'),
    ('unknown_route_404', 'GET', '/not-registered', 404, None),
    ('unmatched_method_404', 'POST', '/ok', 404, None),
]


def request(port: int, method: str, path: str):
    conn = http.client.HTTPConnection(HOST, port, timeout=8)
    try:
        conn.request(method, path)
        resp = conn.getresponse()
        status = resp.status
        fields = {k.lower(): v for k, v in resp.getheaders()}
        body = resp.read()
        return status, fields, body
    finally:
        conn.close()


def check_case(row, status, fields, body):
    name, _method, _path, expected_status, expected_body = row
    assert status == expected_status, f'expected {expected_status}, got {status}'
    if expected_body is not None:
        assert body == expected_body, f'expected {expected_body!r}, got {body[:140]!r}'
    if name == 'redirect_303':
        assert fields.get('location') == '/ok', fields
    if name == 'handler_exception_fallback' or name == 'empty_404_default':
        assert b'Internal Server Error' in body or b'Not Found' in body, body[:140]
    for secret in (b'STEP15_PRIVATE_TOKEN', b'STEP15_HANDLER_TOKEN',
                   b'STEP15_INTERNAL_TOKEN', b'Traceback', b'asyncdispatch.nim'):
        assert secret not in body, f'sensitive text in {name}'


def run(out: Path, mode: str):
    results = []
    outputs = {}
    for name, method, path, expected_status, expected_body in CASES:
        values = {}
        for label, port in PORTS.items():
            try:
                status, headers, body = request(port, method, path)
                check_case((name, method, path, expected_status, expected_body),
                           status, headers, body)
                # Ignore Date, ETag and socket-specific headers during comparison.
                values[label] = (status, headers.get('content-type'),
                                 headers.get('location'), body)
            except Exception as exc:
                values[label] = repr(exc)
        passed = (all(isinstance(v, tuple) for v in values.values()) and
                  len(set(values.values())) == 1)
        results.append({'name': name, 'passed': passed,
                        'expected': str(expected_status),
                        'observed': {k: (f'{v[0]}, {len(v[3])} bytes' if isinstance(v, tuple)
                                         else str(v)) for k, v in values.items()}})
        if not passed:
            print(f'FAIL {name}: {values}', flush=True)
    # Verify the second synchronous matcher is really registered.
    secondary_status, _, secondary_body = request(PORTS['sync_multiple'],
                                                   'GET', '/secondary-only')
    secondary_ok = secondary_status == 200 and secondary_body == b'secondary'
    results.append({'name': 'second_matcher_registered', 'passed': secondary_ok,
                    'expected': '200 secondary',
                    'observed': {'sync_multiple': f'{secondary_status} {secondary_body!r}'}})
    if not secondary_ok:
        print('FAIL: second synchronous matcher not registered', flush=True)

    # Record comparable sequential keep-alive timings for informational use.
    # No hard latency thresholds are asserted (CI machines vary widely).
    timings = {}
    for label in ('sync_single', 'sync_multiple'):
        conn = http.client.HTTPConnection(HOST, PORTS[label], timeout=8)
        elapsed = []
        try:
            for _ in range(30):
                conn.request('GET', '/ok')
                res = conn.getresponse()
                assert res.status == 200 and res.read() == b'hello'
            for _ in range(300):
                start = time.perf_counter_ns()
                conn.request('GET', '/ok')
                res = conn.getresponse()
                assert res.status == 200 and res.read() == b'hello'
                elapsed.append((time.perf_counter_ns() - start) / 1e6)
        finally:
            conn.close()
        timings[label] = {'requests': len(elapsed),
                          'median_ms': round(statistics.median(elapsed), 4),
                          'p95_ms': round(sorted(elapsed)[int(len(elapsed)*.95)-1], 4)}

    passed = sum(r['passed'] for r in results)
    record = {'mode': mode, 'passed': passed, 'total': len(results),
              'results': results, 'timings': timings}
    (out / f'step15-{mode}.json').write_text(json.dumps(record, indent=2) + '\n')
    print(f'Step 15 {mode}: {passed}/{len(results)} PASS', flush=True)
    print(f'Step 15 {mode} timing (informational): {timings}', flush=True)
    return passed == len(results)


if __name__ == '__main__':
    ok = run(Path(sys.argv[1]), sys.argv[2])
    raise SystemExit(0 if ok else 1)
