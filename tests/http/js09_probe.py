#!/usr/bin/env python3
"""JS-09: check static URL restrictions without modifying explicit sendFile.

Usage:
    js09_probe.py setup STATIC_ROOT EXPLICIT_FILE
    js09_probe.py run OUT MODE PORT SERVER_PID
"""
from __future__ import annotations

import http.client
import json
import os
import sys
import time
from pathlib import Path

HOST = "127.0.0.1"
SECRET = b"JS09-AUTOMATIC-STATIC-SECRET-MUST-NOT-LEAK"
EXPLICIT = b"JS09-EXPLICIT-PRIVATE-CONTENT"


def setup(root: Path, explicit_file: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)
    for sub in (".git", ".well-known", "sub", "sub/.git"):
        (root / sub).mkdir(parents=True, exist_ok=True)
    assets = {
        "index.html": b"JS09-PUBLIC-INDEX",
        "sub/visible.txt": b"JS09-VISIBLE",
        "sub/data.bak": b"JS09-BACKUP-NAME-IS-NOT-BLOCKED",
        "%2eenv": b"JS09-SINGLE-DECODE-NAME",
        ".env": SECRET,
        ".git/config": SECRET,
        "sub/.config": SECRET,
        "sub/.git/config": SECRET,
        ".well-known/acme.txt": SECRET,
    }
    for rel, data in assets.items():
        target = root / rel
        target.write_bytes(data)
        target.chmod(0o644)
    explicit_file.parent.mkdir(parents=True, exist_ok=True)
    explicit_file.write_bytes(EXPLICIT)
    explicit_file.chmod(0o644)


def request(port: int, path: str, method: str = "GET",
            headers: dict[str, str] | None = None):
    conn = http.client.HTTPConnection(HOST, port, timeout=5)
    try:
        conn.putrequest(method, path)
        conn.putheader("Connection", "close")
        for key, value in (headers or {}).items():
            conn.putheader(key, value)
        conn.endheaders()
        response = conn.getresponse()
        return response.status, response.read(), {
            key.lower(): value for key, value in response.getheaders()
        }
    finally:
        conn.close()


def ready(port: int) -> None:
    until = time.monotonic() + 6.0
    while time.monotonic() < until:
        try:
            status, body, _ = request(port, "/ping")
            if status == 200 and body == b"pong":
                return
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(0.05)
    raise RuntimeError(f"JS-09 server not ready on port {port}")


def run(out: Path, mode: str, port: int, pid: int) -> int:
    ready(port)
    cases: list[dict[str, object]] = []

    def check(name: str, action) -> None:
        try:
            ok = bool(action())
            detail = "" if ok else "unexpected HTTP status, headers or body"
        except Exception as exc:
            ok = False
            detail = repr(exc)
        cases.append({"name": name, "result": "PASS" if ok else "FAIL",
                      "detail": detail})
        print(f"{'PASS' if ok else 'FAIL'} {mode}: {name} {detail}")

    def denied(path: str, method: str = "GET", headers=None) -> bool:
        status, body, _ = request(port, path, method, headers)
        return status == 404 and SECRET not in body

    def public(path: str, data: bytes) -> bool:
        code, body, headers = request(port, path)
        return (code == 200 and body == data and
                int(headers.get("content-length", "-1")) == len(data))

    check("public_index", lambda: public("/index.html", b"JS09-PUBLIC-INDEX"))
    check("public_nested", lambda: public("/sub/visible.txt", b"JS09-VISIBLE"))
    check("backup_extension_compatibility", lambda: public(
        "/sub/data.bak", b"JS09-BACKUP-NAME-IS-NOT-BLOCKED"))
    check("exactly_one_percent_decode", lambda: public(
        "/%252eenv", b"JS09-SINGLE-DECODE-NAME"))

    for name, path in (
        ("hidden_file", "/.env"),
        ("hidden_directory", "/.git/config"),
        ("nested_hidden_file", "/sub/.config"),
        ("nested_hidden_directory", "/sub/.git/config"),
        ("well_known_is_hidden", "/.well-known/acme.txt"),
        ("encoded_leading_dot", "/%2eenv"),
        ("encoded_letter_in_hidden_name", "/.%65nv"),
        ("encoded_hidden_directory", "/%2Egit/config"),
        ("encoded_nested_dot", "/sub/%2econfig"),
        ("encoded_well_known", "/%2ewell-known/acme.txt"),
    ):
        check(name, lambda path=path: denied(path))

    check("head_hidden_404", lambda: denied("/.env", "HEAD"))
    check("conditional_hidden_not_304", lambda: denied(
        "/.env", "GET", {"If-None-Match": "*"}))
    check("explicit_outside_dotfile", lambda: public(
        "/explicit-private", EXPLICIT))
    check("explicit_conditional_304", lambda: explicit_cached(port))

    def no_fd_leak() -> bool:
        before = len(os.listdir(f"/proc/{pid}/fd"))
        for _ in range(40):
            assert denied("/.env")
            assert denied("/.git/config")
            assert request(port, "/index.html")[0] == 200
            assert request(port, "/explicit-private")[0] == 200
        after = len(os.listdir(f"/proc/{pid}/fd"))
        return after <= before + 3

    check("fd_recovery", no_fd_leak)
    check("ping_after", lambda: request(port, "/ping")[:2] == (200, b"pong"))

    record = {"mode": mode, "passed": sum(
        r["result"] == "PASS" for r in cases), "total": len(cases),
        "results": cases}
    (out / f"js09-{mode}.json").write_text(
        json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return 0 if record["passed"] == record["total"] else 1


def explicit_cached(port: int) -> bool:
    status, body, headers = request(port, "/explicit-private")
    etag = headers.get("etag")
    if status != 200 or body != EXPLICIT or not etag:
        return False
    cached_status, cached_body, cached_headers = request(
        port, "/explicit-private", headers={"If-None-Match": etag})
    return (cached_status == 304 and cached_body == b"" and
            cached_headers.get("etag") == etag)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "setup":
        setup(Path(sys.argv[2]), Path(sys.argv[3]))
    elif len(sys.argv) == 6 and sys.argv[1] == "run":
        raise SystemExit(run(Path(sys.argv[2]), sys.argv[3],
                             int(sys.argv[4]), int(sys.argv[5])))
    else:
        raise SystemExit("Usage: js09_probe.py setup ROOT FILE | "
                         "run OUT MODE PORT PID")
