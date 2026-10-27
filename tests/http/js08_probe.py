#!/usr/bin/env python3
"""JS-08 wire-level origin and generated URI checks on 127.0.0.1 only."""
from __future__ import annotations

import http.client
import json
import socket
import sys
import time
from pathlib import Path


def get(port: int, host: str, extra: dict[str, str] | None = None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        conn.putrequest("GET", "/inspect", skip_host=True)
        conn.putheader("Host", host)
        conn.putheader("Connection", "close")
        for key, value in (extra or {}).items():
            conn.putheader(key, value)
        conn.endheaders()
        reply = conn.getresponse()
        return reply.status, reply.read().decode("utf-8")
    finally:
        conn.close()


def wait_ready(port: int, seconds: float = 5) -> None:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=0.3)
            conn.request("GET", "/ping", headers={"Host": "localhost"})
            reply = conn.getresponse()
            data = reply.read()
            conn.close()
            if reply.status == 200 and data == b"pong":
                return
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(0.05)
    raise RuntimeError(f"JS-08 server did not become ready on port {port}")


def run(out: Path, mode: str, policy: str, port: int) -> int:
    wait_ready(port)
    lines: list[dict[str, object]] = []
    base = f"127.0.0.1|false||{port}|/next"

    def check(name: str, host: str, expected: str,
              headers: dict[str, str] | None = None) -> None:
        try:
            status, body = get(port, host, headers)
            passed = status == 200 and body == expected
            detail = "" if passed else f"HTTP {status}, body={body!r}, expected={expected!r}"
        except Exception as exc:
            passed = False
            detail = repr(exc)
        lines.append({"name": name, "result": "PASS" if passed else "FAIL",
                      "detail": detail})
        print(f"{'PASS' if passed else 'FAIL'} {mode}/{policy}: {name} {detail}")

    if policy == "strict":
        check("localhost_excluded", f"localhost:{port}", base)
        check("bind_address_excluded", f"127.0.0.1:{port}", base)
        check("allowed_case_insensitive", "GW.EXAMPLE.TEST:9443",
              "127.0.0.1|false|gw.example.test|9443|http://gw.example.test:9443/next")
        check("subdomain_not_allowed", "gw.example.test.attacker", base)
        check("trusted_x_forwarded_localhost_rejected", f"localhost:{port}",
              f"127.0.0.1|true||{port}|/next",
              {"X-Forwarded-Host": "localhost", "X-Forwarded-Proto": "https"})
        check("trusted_x_forwarded_allowed", f"localhost:{port}",
              "127.0.0.1|true|gw.example.test|443|https://gw.example.test/next",
              {"X-Forwarded-Host": "GW.EXAMPLE.TEST", "X-Forwarded-Proto": "https"})
        check("trusted_rfc_forwarded_localhost_rejected", f"localhost:{port}",
              f"198.51.100.7|true||{port}|/next",
              {"Forwarded": "for=198.51.100.7;proto=https;host=localhost"})
        check("trusted_rfc_forwarded_allowed", f"localhost:{port}",
              "198.51.100.7|true|gw.example.test|443|https://gw.example.test/next",
              {"Forwarded": "for=198.51.100.7;proto=https;host=GW.EXAMPLE.TEST"})
    elif policy == "default":
        check("localhost_default", f"localhost:{port}",
              f"127.0.0.1|false|localhost|{port}|http://localhost:{port}/next")
        check("bind_default", f"127.0.0.1:{port}",
              f"127.0.0.1|false|127.0.0.1|{port}|http://127.0.0.1:{port}/next")
        check("unknown_default", "attacker.example", base)
    elif policy == "public":
        fixed = "127.0.0.1|true|fixed.example.test|8443|https://fixed.example.test:8443/next"
        check("public_base_overrides_localhost", f"localhost:{port}", fixed)
        check("public_base_overrides_unknown", "attacker.example", fixed)
    else:
        raise ValueError(policy)

    record = {"build": mode, "policy": policy, "passed": sum(
        item["result"] == "PASS" for item in lines), "total": len(lines),
        "tests": lines}
    (out / f"js08-{mode}-{policy}.json").write_text(
        json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return 0 if record["passed"] == record["total"] else 1


if __name__ == "__main__":
    if len(sys.argv) != 5:
        raise SystemExit("usage: js08_probe.py OUT BUILD POLICY PORT")
    raise SystemExit(run(Path(sys.argv[1]), sys.argv[2], sys.argv[3],
                         int(sys.argv[4])))
