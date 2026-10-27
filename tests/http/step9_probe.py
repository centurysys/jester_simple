#!/usr/bin/env python3
"""Step 9: loopback-only Host and forwarding spoofing checks."""
from __future__ import annotations
import http.client
import ipaddress
import json
import socket
import sys
from pathlib import Path
from datetime import datetime, timezone

HOST = '127.0.0.1'


def request(port, headers=None, raw=None):
    if raw is None:
        conn = http.client.HTTPConnection(HOST, port, timeout=4)
        try:
            conn.putrequest('GET', '/inspect', skip_host=True)
            for key, value in (headers or {}).items():
                conn.putheader(key, value)
            conn.endheaders()
            reply = conn.getresponse()
            return reply.status, reply.read(4096).decode('ascii', 'replace')
        finally:
            conn.close()
    with socket.create_connection((HOST, port), timeout=4) as sock:
        sock.settimeout(4)
        sock.sendall(raw)
        data = b''
        while b'\r\n' not in data and len(data) < 8192:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        if not data.startswith(b'HTTP/'):
            return None, data.decode('ascii', 'replace')
        return int(data.split(b' ', 2)[1]), data.decode('ascii', 'replace')


def main():
    output, mode = Path(sys.argv[1]), sys.argv[2]
    rows = []

    def test(name, port, hdr, code, body=None, raw=None):
        try:
            status, text = request(port, hdr, raw)
            passed = status == code and (body is None or text == body)
            # Nim's IPv6 text representation may differ; compare the IP
            # semantically while checking all remaining metadata verbatim.
            if name == 'trusted_rfc_forwarded' and status == code and body:
                actual = text.split('|', 1)
                expected = body.split('|', 1)
                try:
                    passed = (len(actual) == 2 and len(expected) == 2
                              and ipaddress.ip_address(actual[0]) ==
                                  ipaddress.ip_address(expected[0])
                              and actual[1] == expected[1])
                except ValueError:
                    passed = False
            rows.append(dict(test=name, status=status, expected=code,
                             result='PASS' if passed else 'FAIL',
                             detail='' if passed else repr(text[:250])))
        except Exception as exc:
            rows.append(dict(test=name, status=None, expected=code,
                             result='FAIL', detail=repr(exc)))

    # Local test host is deliberately included in the default safe host set.
    test('direct_control', 5487, {'Host': 'localhost:5487'}, 200,
         '127.0.0.1|false|localhost|5487|http://localhost:5487/next')
    test('direct_spoofed_headers', 5487, {'Host': 'localhost:5487',
         'REMOTE_ADDR': '203.0.113.55', 'X-Forwarded-For': '198.51.100.23',
         'X-Forwarded-Proto': 'https', 'X-Forwarded-Host': 'evil.test'}, 200,
         '127.0.0.1|false|localhost|5487|http://localhost:5487/next')
    test('direct_untrusted_host_relative', 5487, {'Host': 'attacker.example'}, 200,
         '127.0.0.1|false||5487|/next')
    test('direct_untrusted_forwarded', 5487, {'Host': 'localhost:5487',
         'Forwarded': 'for=198.51.100.5;proto=https;host=evil.test'}, 200,
         '127.0.0.1|false|localhost|5487|http://localhost:5487/next')
    test('trusted_x_forwarded', 5488, {'Host': 'localhost:5488',
         'X-Forwarded-For': '198.51.100.5', 'X-Forwarded-Proto': 'https',
         'X-Forwarded-Host': 'gw.example.test'}, 200,
         '198.51.100.5|true|gw.example.test|443|https://gw.example.test/next')
    test('trusted_x_forwarded_port', 5488, {'Host': 'localhost:5488',
         'X-Forwarded-For': '203.0.113.1, 198.51.100.5',
         'X-Forwarded-Proto': 'http, https',
         'X-Forwarded-Host': 'gw.example.test:9443'}, 200,
         '198.51.100.5|true|gw.example.test|9443|https://gw.example.test:9443/next')
    test('trusted_rfc_forwarded', 5488, {'Host': 'localhost:5488',
         'Forwarded': 'for="[2001:db8::1]";proto=https;host="gw.example.test:8443"'}, 200,
         '2001:db8::1|true|gw.example.test|8443|https://gw.example.test:8443/next')
    test('trusted_rfc_chain_rightmost', 5488, {'Host': 'localhost:5488',
         'Forwarded': 'for=203.0.113.1;proto=http;host=evil.test, '
                      'for=192.0.2.4;proto=https;host=gw.example.test'}, 200,
         '192.0.2.4|true|gw.example.test|443|https://gw.example.test/next')
    test('trusted_mixed_header_families_ignored', 5488, {'Host': 'localhost:5488',
         'Forwarded': 'for=192.0.2.4;proto=https;host=gw.example.test',
         'X-Forwarded-For': '203.0.113.200', 'X-Forwarded-Proto': 'http'}, 200,
         '127.0.0.1|false|localhost|5488|http://localhost:5488/next')
    test('trusted_invalid_forwarded_for', 5488, {'Host': 'localhost:5488',
         'Forwarded': 'for=unknown;proto=https;host=gw.example.test'}, 200,
         '127.0.0.1|true|gw.example.test|443|https://gw.example.test/next')
    test('trusted_host_not_allowed', 5488, {'Host': 'localhost:5488',
         'X-Forwarded-Host': 'evil.test', 'X-Forwarded-Proto': 'https'}, 200,
         '127.0.0.1|true||5488|/next')
    test('public_base_fixed_origin', 5489, {'Host': 'attacker.example',
         'X-Forwarded-For': '198.51.100.12', 'X-Forwarded-Proto': 'http'}, 200,
         '127.0.0.1|true|gateway.example.test|8443|https://gateway.example.test:8443/next')

    for name, msg in [
        ('missing_host', b'GET /inspect HTTP/1.1\r\nConnection: close\r\n\r\n'),
        ('duplicate_host', b'GET /inspect HTTP/1.1\r\nHost: localhost:5487\r\nhOsT: evil.test\r\n\r\n'),
        ('malformed_host_userinfo', b'GET /inspect HTTP/1.1\r\nHost: evil@host\r\n\r\n'),
        ('malformed_host_port', b'GET /inspect HTTP/1.1\r\nHost: example.com:70000\r\n\r\n'),
        ('malformed_host_ipv6', b'GET /inspect HTTP/1.1\r\nHost: [:::]\r\n\r\n'),
        ('duplicate_forwarded', b'GET /inspect HTTP/1.1\r\nHost: localhost:5487\r\nForwarded: for=192.0.2.1\r\nforwarded: for=192.0.2.2\r\n\r\n'),
    ]:
        test(name, 5487, None, 400, raw=msg)
    test('control_after', 5487, {'Host': 'localhost:5487'}, 200,
         '127.0.0.1|false|localhost|5487|http://localhost:5487/next')

    passed = sum(x['result'] == 'PASS' for x in rows)
    record = dict(mode=mode, captured_utc=datetime.now(timezone.utc).isoformat(),
                  passed=passed, total=len(rows), results=rows)
    output.mkdir(parents=True, exist_ok=True)
    (output / f'step9-{mode}.json').write_text(json.dumps(record, indent=2)+'\n')
    print(f'Step 9 {mode}: {passed}/{len(rows)} PASS')
    for row in rows:
        if row['result'] != 'PASS':
            print('FAIL:', row['test'], row['detail'])
    return 0 if passed == len(rows) else 1


if __name__ == '__main__':
    sys.exit(main())
