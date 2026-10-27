#!/usr/bin/env python3
"""JS-11: validate copied settings and contain origin-init failures."""
import argparse
import http.client
import json
import os
import pathlib
import socket
import time


def request(port, path, host="gw.example.test"):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        conn.request("GET", path, headers={"Host": host, "Connection": "close"})
        resp = conn.getresponse()
        body = resp.read().decode("utf-8", errors="replace")
        return resp.status, body
    finally:
        conn.close()


def wait_ready(port):
    for _ in range(100):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=.1):
                return
        except OSError:
            time.sleep(.05)
    raise RuntimeError("Server not ready")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    wait_ready(args.port)
    checks = []

    def check(name, condition, detail):
        checks.append({"name": name, "result": "PASS" if condition else "FAIL", "detail": detail})
        print(checks[-1]["result"], name)

    status, body = request(args.port, "/inspect")
    check("baseline_origin", status == 200 and body == f"gw.example.test|http://gw.example.test:{args.port}/next", (status, body))

    status, body = request(args.port, "/mutate-external")
    check("mutate_caller_settings", status == 200 and body == "mutated-external", (status, body))

    status, body = request(args.port, "/inspect")
    check("runtime_snapshot_isolated", status == 200 and body == f"gw.example.test|http://gw.example.test:{args.port}/next", (status, body))

    status, body = request(args.port, "/poison-internal")
    check("mutate_live_settings", status == 200 and body == "mutated-internal", (status, body))

    status, body = request(args.port, "/inspect")
    check("bad_origin_yields_500", status == 500 and "Internal Server Error" in body, (status, body[:80]))

    status, body = request(args.port, "/ping")
    check("server_survives_bad_origin", status == 500, (status, body[:80]))

    pathlib.Path(args.output).write_text(json.dumps(checks, indent=2) + "\n")
    if any(c["result"] != "PASS" for c in checks):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
