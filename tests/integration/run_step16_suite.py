#!/usr/bin/env python3
"""Run all core and HTTP regression gates, recording every result.

Run this Python process from an interactive shell. Failures stop only this
child process, never the interactive shell. It continues after each failure
so multiple regressions are visible in one report.
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STEP_IDS = list(range(5, 16))


def jobs(base: Path, *, with_baseline: bool):
    result = [("core", ["nimble", "test", "-y"])]
    for step in STEP_IDS:
        result.append((f"step{step}", [
            "bash", f"tests/http/run_step{step}.sh",
            str(base / f"step{step}-artifacts"),
        ]))
    result.append(("step16", [
        "bash", "tests/integration/run_step16.sh",
        str(base / "step16-artifacts"),
    ]))
    if with_baseline:
        result.append(("baseline", [
            "bash", "tests/baseline/run_step0.sh",
            str(base / "baseline-artifacts"),
        ]))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path,
                        default=Path("docs/modernization/step16-suite-results"))
    parser.add_argument("--only", choices=["all", "core", "step16"], default="all",
                        help="all (default), core integration, or cross-feature only")
    parser.add_argument("--skip-baseline", action="store_true")
    parser.add_argument("--timeout", type=int, default=900,
                        help="per-stage timeout in seconds (default: 900)")
    args = parser.parse_args()
    if args.timeout < 10:
        parser.error("--timeout must be >= 10")
    output = args.out
    if not output.is_absolute():
        output = ROOT / output
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    git_head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True,
        check=False,
    ).stdout.strip()
    plan = jobs(output, with_baseline=not args.skip_baseline)
    if args.only != "all":
        plan = [(name, cmd) for name, cmd in plan if name == args.only]

    results = []
    for name, command in plan:
        logfile = output / f"{name}.log"
        start = time.monotonic()
        print(f"=== {name} ===", flush=True)
        try:
            with logfile.open("w", encoding="utf-8", errors="replace") as stream:
                # Isolate child process groups so a timeout also cleans up
                # any HTTP test server launched by the shell runner.
                proc = subprocess.Popen(
                    command, cwd=ROOT, stdout=stream,
                    stderr=subprocess.STDOUT, start_new_session=True,
                )
                try:
                    code = proc.wait(timeout=args.timeout)
                    status = "PASS" if code == 0 else "FAIL"
                except subprocess.TimeoutExpired:
                    code, status = None, "TIMEOUT"
                    os.killpg(proc.pid, signal.SIGTERM)
                    try:
                        proc.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(proc.pid, signal.SIGKILL)
                        proc.wait()
                    stream.write(f"\nTIMEOUT after {args.timeout} seconds\n")
        except OSError as exc:
            code, status = None, "ERROR"
            with logfile.open("a", encoding="utf-8") as stream:
                stream.write(f"\nExecution error: {exc}\n")
        duration = round(time.monotonic() - start, 2)
        results.append({"stage": name, "status": status,
                        "exit_code": code, "elapsed_seconds": duration,
                        "log": str(logfile.relative_to(output))})
        print(f"{name}: {status} ({duration:.2f}s) -> {logfile}", flush=True)

    record = {"git_head": git_head, "results": results,
              "passed": sum(r["status"] == "PASS" for r in results),
              "total": len(results)}
    (output / "RESULTS.json").write_text(
        json.dumps(record, indent=2) + "\n", encoding="utf-8")
    md = ["# Step 16 full regression suite", "",
          f"Source commit: `{git_head or 'unavailable'}`", "",
          "| Stage | Result | Seconds | Log |", "| --- | --- | ---: | --- |"]
    for r in results:
        md.append(f"| {r['stage']} | {r['status']} | {r['elapsed_seconds']:.2f} | "
                  f"`{r['log']}` |")
    md += ["", f"**{record['passed']}/{record['total']} stages passed.**", "",
           "The subprocess runner does not exit the invoking interactive shell.",
           "Individual HTTP suites save additional case-level reports under",
           "their `*-artifacts` directories.", ""]
    (output / "REPORT.md").write_text("\n".join(md), encoding="utf-8")
    print(f"=== {record['passed']}/{record['total']} stages passed ===", flush=True)
    print(f"Full report: {output / 'REPORT.md'}", flush=True)
    return 0 if record["passed"] == record["total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
