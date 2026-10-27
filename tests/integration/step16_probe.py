#!/usr/bin/env python3
"""Step 16: cross-feature HTTP regression tests, loopback only.

Only Python's standard library is used. Each case is isolated so a failed
assertion does not hide subsequent cross-feature regressions.
"""
from __future__ import annotations

import http.client
import json
import socket
import sys
from pathlib import Path

HOST = "127.0.0.1"
PORT = 5499
SECRET_MARKERS = (
    b"STEP16_PRIVATE_EXCEPTION", b"STEP16_NEVER_SEND_COOKIE",
    b"Traceback", b"asyncdispatch.nim",
)


def http_request(method, path, *, headers=None, body=None, connection=None):
    own = connection is None
    conn = connection or http.client.HTTPConnection(HOST, PORT, timeout=5)
    try:
        conn.request(method, path, body=body, headers=headers or {})
        res = conn.getresponse()
        data = res.read()
        return res.status, res.getheaders(), data
    finally:
        if own:
            conn.close()


def field_values(fields, name):
    return [value for key, value in fields if key.lower() == name.lower()]


def expect_response(
    method, path, status, expected_body=None,
    *, request_body=None, headers=None, connection=None,
):
    observed, fields, payload = http_request(
        method, path, headers=headers, body=request_body, connection=connection,
    )
    assert observed == status, f"HTTP {observed}, expected {status}"
    if expected_body is not None:
        assert payload == expected_body, (
            f"body length {len(payload)} did not match expected"
        )
    for marker in SECRET_MARKERS:
        assert marker not in payload, f"response leaked marker {marker!r}"
    return fields, payload


def raw_request(request_bytes):
    with socket.create_connection((HOST, PORT), timeout=4) as sock:
        sock.settimeout(4)
        sock.sendall(request_bytes)
        sock.shutdown(socket.SHUT_WR)
        chunks = []
        remaining = 32768
        try:
            while remaining > 0:
                chunk = sock.recv(min(4096, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
        except (TimeoutError, socket.timeout):
            pass
    result = b"".join(chunks)
    assert result.startswith(b"HTTP/1.1 "), f"no HTTP status line: {result[:80]!r}"
    return int(result.split(b" ", 2)[1]), result


def check_raw_400(payload):
    code, wire = raw_request(payload)
    assert code == 400, f"malformed HTTP returned {code}"
    assert b"STEP16_PRIVATE_EXCEPTION" not in wire
    # A rejected request must never be followed by a pipelined success reply.
    assert wire.count(b"HTTP/1.1 ") == 1, "pipelined request was dispatched"


def multipart_payload(boundary, data, *, final=True):
    result = (
        b"--" + boundary + b"\r\n"
        b'Content-Disposition: form-data; name="note"\r\n'
        b"Content-Type: application/octet-stream\r\n\r\n"
        + data + b"\r\n"
    )
    if final:
        result += b"--" + boundary + b"--\r\n"
    return result


def run(out, mode):
    cases = []

    def check(name, callback):
        try:
            callback()
            cases.append({"name": name, "passed": True, "detail": ""})
        except Exception as exc:
            detail = f"{type(exc).__name__}: {str(exc)[:200]}"
            cases.append({"name": name, "passed": False, "detail": detail})
            print(f"FAIL {name}: {detail}", flush=True)

    check("ping_control", lambda: expect_response("GET", "/ping", 200, b"pong"))

    def origin_spoofing():
        fields, payload = expect_response(
            "GET", "/origin", 200, headers={
                "X-Forwarded-For": "198.51.100.77",
                "X-Forwarded-Proto": "https",
                "X-Forwarded-Host": "attacker.invalid",
                "Forwarded": "for=203.0.113.3;proto=https;host=attacker.invalid",
            })
        text = payload.decode("ascii")
        assert text.startswith("127.0.0.1|false|"), text[:100]
        assert "attacker.invalid" not in text
        assert "https://" not in text
    check("untrusted_proxy_metadata", origin_spoofing)

    check("query_decoded_once_with_spoofed_ip", lambda: expect_response(
        "GET", "/query?v=%252F", 200, b"%2F",
        headers={"X-Forwarded-For": "198.51.100.88"}))
    check("query_plus_decoding", lambda: expect_response(
        "GET", "/query?v=a+b", 200, b"a b"))
    check("form_decoded_once", lambda: expect_response(
        "POST", "/form", 200, b"%25", headers={
            "Content-Type": "application/x-www-form-urlencoded"}, request_body=b"v=%2525"))
    check("malformed_query_rejected", lambda: expect_response(
        "GET", "/query?v=%G0", 400))
    check("normal_query_after_bad_query", lambda: expect_response(
        "GET", "/query?v=ok", 200, b"ok"))

    def valid_multipart():
        boundary = b"step16-example-boundary"
        value = b"a\x00b\r\n--not-the-real-boundary\r\nc"
        body = multipart_payload(boundary, value)
        expect_response("POST", "/upload", 200, value, headers={
            "Content-Type": "multipart/form-data; boundary=" + boundary.decode(),
        }, request_body=body)
    check("multipart_binary_and_boundary_like_bytes", valid_multipart)

    def invalid_multipart():
        boundary = b"step16-example-boundary"
        body = multipart_payload(boundary, b"incomplete", final=False)
        expect_response("POST", "/upload", 400, headers={
            "Content-Type": "multipart/form-data; boundary=" + boundary.decode(),
        }, request_body=body)
    check("malformed_multipart_rejected", invalid_multipart)
    check("normal_request_after_multipart_error", lambda: expect_response(
        "GET", "/ping", 200, b"pong"))

    def cookies_and_query():
        headers, payload = expect_response("GET", "/cookies?v=%252F", 200, b"%2F")
        cookies = field_values(headers, "set-cookie")
        assert len(cookies) == 2, f"expected 2 Set-Cookie fields, got {len(cookies)}"
        assert any(v.startswith("sid=one;") for v in cookies)
        assert any(v.startswith("theme=light;") for v in cookies)
    check("multiple_set_cookie_with_encoded_query", cookies_and_query)

    def mixed_case_cookies():
        headers, _ = expect_response("GET", "/cookies-mixed", 200, b"mixed")
        cookies = field_values(headers, "Set-Cookie")
        assert len(cookies) == 2, cookies
        assert "legacy=1" in cookies
        assert any(v.startswith("second=2") for v in cookies)
    check("mixed_case_set_cookie_preserved", mixed_case_cookies)

    check("invalid_cookie_no_reflection", lambda: expect_response(
        "GET", "/invalid-cookie", 500))

    def relative_redirect():
        headers, body = expect_response("GET", "/redirect", 303, b"", headers={
            "X-Forwarded-Host": "attacker.invalid",
            "X-Forwarded-Proto": "https",
        })
        assert field_values(headers, "location") == ["/ping"]
    check("redirect_not_poisoned_by_forwarding", relative_redirect)
    check("exception_page_no_secrets", lambda: expect_response(
        "GET", "/exception", 500))

    def raw_and_recovery():
        expect_response("GET", "/raw", 200, b"raw-response")
        expect_response("GET", "/ping", 200, b"pong")
    check("raw_send_followed_by_normal_request", raw_and_recovery)

    def static_metadata():
        headers, data = expect_response("GET", "/static.txt", 200, b"step16-static-data")
        etags = field_values(headers, "etag")
        assert len(etags) == 1 and etags[0], "missing static ETag"
        assert field_values(headers, "content-length") == [str(len(data))]
        hstatus, hfields, hbody = http_request("HEAD", "/static.txt")
        assert hstatus == 200 and hbody == b""
        assert field_values(hfields, "etag") == etags
        assert field_values(hfields, "content-length") == [str(len(data))]
        code, _, not_modified_body = http_request(
            "GET", "/static.txt", headers={"If-None-Match": etags[0]})
        assert code == 304 and not_modified_body == b""
    check("static_get_head_and_conditional_304", static_metadata)

    def static_symlink():
        status, _, data = http_request("GET", "/outside.txt")
        assert status in (400, 403, 404), status
        assert b"step16-secret-file" not in data
    check("static_symlink_remains_confined", static_symlink)

    def ambiguous_framing():
        check_raw_400(
            b"POST /form HTTP/1.1\r\nHost: 127.0.0.1:5499\r\n"
            b"Content-Length: 0\r\nTransfer-Encoding: chunked\r\n"
            b"Connection: close\r\n\r\n"
            b"0\r\n\r\n"
            b"GET /ping HTTP/1.1\r\nHost: 127.0.0.1:5499\r\n\r\n"
        )
    check("cl_te_ambiguity_and_pipelined_request_rejected", ambiguous_framing)

    def conflicting_cl():
        check_raw_400(
            b"POST /upload HTTP/1.1\r\nHost: 127.0.0.1:5499\r\n"
            b"Content-Length: 0\r\nContent-Length: 4\r\n"
            b"Connection: close\r\n\r\n"
        )
    check("conflicting_cl_before_multipart_rejected", conflicting_cl)

    def duplicate_host():
        check_raw_400(
            b"GET /origin HTTP/1.1\r\nHost: 127.0.0.1:5499\r\n"
            b"Host: attacker.invalid\r\nConnection: close\r\n\r\n"
        )
    check("duplicate_host_before_origin_resolution_rejected", duplicate_host)

    def persistent_connection():
        conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
        try:
            for method, path, value in [
                ("GET", "/cookies?v=one", b"one"),
                ("GET", "/query?v=%252F", b"%2F"),
                ("GET", "/static.txt", b"step16-static-data"),
                ("GET", "/ping", b"pong"),
            ]:
                expect_response(method, path, 200, value, connection=conn)
        finally:
            conn.close()
    check("mixed_features_over_one_keepalive_socket", persistent_connection)
    check("ping_after_all_invalid_input", lambda: expect_response(
        "GET", "/ping", 200, b"pong"))

    passed = sum(case["passed"] for case in cases)
    report = {"mode": mode, "passed": passed, "total": len(cases), "cases": cases}
    (out / f"step16-{mode}.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Step 16 {mode}: {passed}/{len(cases)} PASS", flush=True)
    return passed == len(cases)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: step16_probe.py OUTPUT_DIR debug|release", file=sys.stderr)
        sys.exit(2)
    sys.exit(0 if run(Path(sys.argv[1]), sys.argv[2]) else 1)
