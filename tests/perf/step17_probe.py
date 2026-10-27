#!/usr/bin/env python3
"""Loopback-only performance/footprint measurements (no pip dependencies).

Single persistent HTTP/1.1 connection, serial requests; a client-limited
latency/RPS indicator, NOT a maximum server throughput benchmark.
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import platform
import statistics
import sys
import time
from datetime import datetime, timezone

HOST = "127.0.0.1"
PORT = 5517
SMALL = b"step17 small static fixture\n"
POST = b"bench-post"
ROUTES = (
    ("plain", "GET", "/bench/plain", b"OK", "short"),
    ("json", "GET", "/bench/json", b'{"status":"ok","count":42}', "short"),
    ("query", "GET", "/bench/query?q=test&field=5", b"q=test&field=5", "short"),
    ("post", "POST", "/bench/echo", POST, "short"),
    ("static_small", "GET", "/small.txt", SMALL, "short"),
    ("static_large", "GET", "/large.bin", None, "large"),
    ("static_huge", "GET", "/huge.bin", None, "huge"),
)


def percentile(values: list[float], percentage: float) -> float:
    if not values:
        raise ValueError("percentile of empty data")
    data = sorted(values)
    position = (len(data) - 1) * percentage / 100
    low, high = math.floor(position), math.ceil(position)
    return data[low] + (data[high] - data[low]) * (position - low)


def read_proc(pid: int) -> dict:
    status = Path(f"/proc/{pid}/status").read_text()
    result = {}
    for name, key in (("VmRSS", "rss_kib"), ("VmHWM", "hwm_kib")):
        for line in status.splitlines():
            if line.startswith(name + ":"):
                result[key] = int(line.split()[1])
                break
    result["fds"] = len(list(Path(f"/proc/{pid}/fd").iterdir()))
    # /proc/PID/stat field 2 contains spaces and parentheses; parse past last ')'.
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    result["cpu_seconds"] = (
        int(fields[11]) + int(fields[12])
    ) / os.sysconf("SC_CLK_TCK")
    return result


def exchange(connection: http.client.HTTPConnection, method: str,
             path: str, expected: bytes | None, large_size: int = 0,
             data_hash: str | None = None) -> float:
    start = time.perf_counter_ns()
    payload = POST if method == "POST" else None
    connection.request(method, path, body=payload)
    response = connection.getresponse()
    if response.status != 200:
        body = response.read(1024)
        raise AssertionError(f"{method} {path}: HTTP {response.status}, {body!r}")
    if expected is not None:
        body = response.read()
        if body != expected:
            raise AssertionError(f"{method} {path}: body mismatch {body[:100]!r}")
    else:
        total = 0
        digest = hashlib.sha256()
        while True:
            chunk = response.read(65536)
            if not chunk:
                break
            total += len(chunk)
            digest.update(chunk)
        if total != large_size or digest.hexdigest() != data_hash:
            raise AssertionError(f"{path}: size/digest mismatch: {total}")
    return (time.perf_counter_ns() - start) / 1_000_000


def measure(pid: int, fixtures: dict, count: int, repeats: int,
            large_count: int, huge_count: int, footprint_count: int) -> dict:
    checkpoints = {"ready": read_proc(pid)}
    cases = []
    # Stable before/after footprint check, not a throughput benchmark.
    conn = http.client.HTTPConnection(HOST, PORT, timeout=20)
    try:
        for _ in range(footprint_count):
            exchange(conn, "GET", "/bench/plain", b"OK")
    finally:
        conn.close()
    checkpoints[f"after_{footprint_count}_requests"] = read_proc(pid)
    for name, method, path, expected, kind in ROUTES:
        current_count = (count if kind == "short" else
                         large_count if kind == "large" else huge_count)
        verify_size = fixtures.get(kind, {}).get("size", 0)
        verify_hash = fixtures.get(kind, {}).get("sha256")
        for iteration in range(1, repeats + 1):
            conn = http.client.HTTPConnection(HOST, PORT, timeout=30)
            try:
                for _ in range(min(20, max(1, current_count // 10))):
                    exchange(conn, method, path, expected, verify_size, verify_hash)
                before = read_proc(pid)
                times = []
                started = time.perf_counter()
                for _ in range(current_count):
                    times.append(exchange(conn, method, path, expected,
                                          verify_size, verify_hash))
                elapsed = time.perf_counter() - started
                after = read_proc(pid)
                cases.append({
                    "route": name, "repeat": iteration, "requests": current_count,
                    "elapsed_s": round(elapsed, 6),
                    "rps": round(current_count / elapsed, 2),
                    "p50_ms": round(percentile(times, 50), 4),
                    "p95_ms": round(percentile(times, 95), 4),
                    "p99_ms": round(percentile(times, 99), 4),
                    "cpu_s": round(after["cpu_seconds"] - before["cpu_seconds"], 4),
                    "rss_after_kib": after.get("rss_kib"),
                    "hwm_after_kib": after.get("hwm_kib"),
                    "fd_after": after["fds"],
                })
            finally:
                conn.close()
        checkpoints["after_" + name] = read_proc(pid)
    return {"checkpoints": checkpoints, "cases": cases}


def write_report(record: dict, output: Path) -> None:
    lines = ["# Step 17 performance and resource measurements", "",
             "Measurement mode: single serial HTTP/1.1 client, persistent connection.",
             "Client-side latency includes Python overhead; **not** server-only latency or peak RPS.",
             "", f"- Source: `{record['label']}`",
             f"- Captured UTC: {record['captured_utc']}",
             f"- Architecture: {record['arch']}",
             f"- Git HEAD: `{record['git_head']}`",
             f"- Binary size: {record['binary_bytes']} bytes", "",
             "| Route | Run | Req | RPS | p50 (ms) | p99 (ms) | Process CPU (s) |", 
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for c in record["cases"]:
        lines.append(f"| {c['route']} | {c['repeat']} | {c['requests']} | "
                     f"{c['rps']:.2f} | {c['p50_ms']:.4f} | {c['p99_ms']:.4f} | {c['cpu_s']:.4f} |")
    lines.extend(["", "## Process checkpoints", "",
                  "| Phase | RSS (KiB) | HWM (KiB) | FDs |", 
                  "| --- | ---: | ---: | ---: |"])
    for name, metric in record["checkpoints"].items():
        lines.append(f"| {name} | {metric.get('rss_kib', 'N/A')} | "
                     f"{metric.get('hwm_kib', 'N/A')} | {metric['fds']} |")
    lines += ["", "Reported HWM is a process lifetime high-water mark, not per-route memory use.",
              "Release acceptance also requires security tests and a real ARM hardware run.", ""]
    (output / "REPORT.md").write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--git-head", default="unknown")
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--count", type=int, default=400)
    parser.add_argument("--footprint-count", type=int, default=1000)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--large-count", type=int, default=10)
    parser.add_argument("--huge-count", type=int, default=2)
    args = parser.parse_args()
    if min(args.count, args.repeats, args.large_count, args.huge_count, args.footprint_count) < 1:
        parser.error("all count arguments must be positive")
    args.out.mkdir(parents=True, exist_ok=True)
    fixtures = json.loads(args.fixtures.read_text(encoding="utf-8"))
    data = measure(args.pid, fixtures, args.count, args.repeats,
                   args.large_count, args.huge_count, args.footprint_count)
    record = {
        "schema_version": 1,
        "label": args.label,
        "captured_utc": datetime.now(timezone.utc).isoformat(),
        "arch": platform.machine(),
        "git_head": args.git_head,
        "binary_bytes": args.binary.stat().st_size,
        "measurement": "python_http_client_persistent_serial",
        "settings": {"count": args.count, "repeats": args.repeats,
                     "large_count": args.large_count,
                     "huge_count": args.huge_count,
                     "footprint_count": args.footprint_count},
        **data,
    }
    (args.out / "RESULTS.json").write_text(
        json.dumps(record, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    write_report(record, args.out)
    print(f"{args.label}: {len(record['cases'])} route runs OK -> {args.out / 'REPORT.md'}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, AssertionError, http.client.HTTPException) as exc:
        print(f"Step 17 benchmark FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
