#!/usr/bin/env python3
"""JS-02: compare on-wire response headers with redacted debug logs.

All test credentials are fictitious, but logs are still kept out of git.
"""
import argparse
import http.client
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

HOST = "127.0.0.1"
BODY = {"/managed": b"managed-ok", "/raw": b"raw-ok", "/ping": b"pong"}
EXPECTED = {
    "/managed": {
        "set-cookie": [
            "sid=JS02_MANAGED_COOKIE_A; HttpOnly; SameSite=Lax",
            "theme=JS02_MANAGED_COOKIE_B; Path=/; SameSite=Lax",
        ],
        "authorization": ["Bearer JS02_MANAGED_AUTH"],
        "x-api-key": ["JS02_MANAGED_API_KEY"],
        "x-custom-metadata": ["JS02_MANAGED_CUSTOM"],
        "location": ["https://example.invalid/?id=JS02_MANAGED_LOCATION"],
    },
    "/raw": {
        "set-cookie": [
            "sid=JS02_RAW_COOKIE_A; HttpOnly",
            "theme=JS02_RAW_COOKIE_B; Path=/",
        ],
        "proxy-authorization": ["Basic JS02_RAW_PROXY_AUTH"],
        "www-authenticate": ["Bearer realm=JS02_RAW_AUTH_CHALLENGE"],
        "x-api-key": ["JS02_RAW_API_KEY"],
        "x-custom-metadata": ["JS02_RAW_CUSTOM"],
    },
}
SECRETS = (
    "JS02_MANAGED_COOKIE_A", "JS02_MANAGED_COOKIE_B", "JS02_MANAGED_AUTH",
    "JS02_MANAGED_API_KEY", "JS02_MANAGED_CUSTOM", "JS02_MANAGED_LOCATION",
    "JS02_RAW_COOKIE_A", "JS02_RAW_COOKIE_B", "JS02_RAW_PROXY_AUTH",
    "JS02_RAW_AUTH_CHALLENGE", "JS02_RAW_API_KEY", "JS02_RAW_CUSTOM",
)


def check_wire(port):
    tests = []
    for path, expected_body in BODY.items():
        connection = http.client.HTTPConnection(HOST, port, timeout=4)
        try:
            connection.request("GET", path, headers={"Connection": "close"})
            reply = connection.getresponse()
            body = reply.read()
            headers = {}
            for key, value in reply.getheaders():
                headers.setdefault(key.lower(), []).append(value)
            expected = EXPECTED.get(path, {})
            errors = []
            if reply.status != 200:
                errors.append(f"status={reply.status}")
            if body != expected_body:
                errors.append(f"body does not match for {path}")
            for key, values in expected.items():
                if headers.get(key) != values:
                    errors.append(f"{key}: expected {len(values)} distinct fields")
            tests.append({"name": path, "result": "PASS" if not errors else "FAIL",
                          "errors": errors, "status": reply.status,
                          "set_cookie_fields": len(headers.get("set-cookie", []))})
        except (OSError, TimeoutError, http.client.HTTPException) as exc:
            tests.append({"name": path, "result": "FAIL", "errors": [repr(exc)]})
        finally:
            connection.close()
    return tests


def check_log(path, mode):
    content = path.read_text(encoding="utf-8", errors="replace")
    errors = []
    for secret in SECRETS:
        if secret in content:
            errors.append("A response header secret appeared in server log")
            break
    if mode == "debug":
        lower = content.lower()
        if "[redacted]" not in lower:
            errors.append("Redaction marker absent in Debug log")
        for name in ("set-cookie", "authorization", "x-api-key",
                     "x-custom-metadata", "content-length"):
            if name not in lower:
                errors.append(f"Expected diagnostic header name missing: {name}")
    return {"name": "server_log_redaction", "result": "PASS" if not errors else "FAIL",
            "errors": errors, "debug_redaction_seen": "[REDACTED]" in content,
            "log_size_bytes": len(content.encode("utf-8"))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("debug", "release"), required=True)
    parser.add_argument("--phase", choices=("wire", "log"), required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--port", type=int)
    parser.add_argument("--server-log", type=Path)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    target = args.out / f"js02-{args.mode}.json"

    if args.phase == "wire":
        if args.port is None:
            parser.error("--port is required for wire phase")
        result = {"captured_utc": datetime.now(timezone.utc).isoformat(),
                  "mode": args.mode, "wire_tests": check_wire(args.port)}
    else:
        if args.server_log is None:
            parser.error("--server-log is required for log phase")
        result = json.loads(target.read_text(encoding="utf-8"))
        result["log_test"] = check_log(args.server_log, args.mode)

    target.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    tests = result.get("wire_tests", [])
    if "log_test" in result:
        tests.append(result["log_test"])
    for test in tests:
        print(f"{test['result']} {args.mode}: {test['name']}")
    return 0 if all(t["result"] == "PASS" for t in tests) else 1


if __name__ == "__main__":
    sys.exit(main())
