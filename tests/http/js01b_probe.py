#!/usr/bin/env python3
"""JS-01b: HTTP-level regression tests for router extend forms."""

import argparse
import http.client
import json
from datetime import datetime, timezone
from pathlib import Path


CASES = (
    ("implicit_prefix", "/implicit", 200, b"implicit-ok"),
    ("explicit_empty_prefix", "/empty", 200, b"empty-ok"),
    ("explicit_prefix_v1", "/v1/item", 200, b"prefix-ok"),
    ("explicit_prefix_v2", "/v2/item", 200, b"prefix-ok"),
    ("nested_prefix", "/v3/item", 200, b"prefix-ok"),
    ("unprefixed_item_rejected", "/item", 404, None),
    ("unexpected_prefix_rejected", "/v4/item", 404, None),
)


def run_case(port, name, path, expected_status, expected_body):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        connection.request("GET", path, headers={"Connection": "close"})
        response = connection.getresponse()
        body = response.read()
        status = response.status
        passed = status == expected_status and (
            expected_body is None or body == expected_body
        )
        return {
            "name": name,
            "result": "PASS" if passed else "FAIL",
            "status": status,
            "expected_status": expected_status,
            "body": body.decode("utf-8", errors="replace")[:200],
        }
    except (OSError, TimeoutError, http.client.HTTPException) as exc:
        return {"name": name, "result": "FAIL", "error": repr(exc)}
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--mode", choices=("debug", "release"), required=True)
    parser.add_argument("--matcher", choices=("single", "multi", "async"), required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    cases = list(CASES)
    if args.matcher == "multi":
        cases.append(("secondary_matcher", "/unrelated", 200, b"unrelated-ok"))

    tests = [run_case(args.port, *case) for case in cases]
    report = {
        "captured_utc": datetime.now(timezone.utc).isoformat(),
        "mode": args.mode,
        "matcher": args.matcher,
        "tests": tests,
    }
    target = args.out / f"js01b-{args.matcher}-{args.mode}.json"
    target.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for test in tests:
        print(f"{test['result']} {args.mode}/{args.matcher}: {test['name']}")
    return 0 if all(test["result"] == "PASS" for test in tests) else 1


if __name__ == "__main__":
    raise SystemExit(main())
