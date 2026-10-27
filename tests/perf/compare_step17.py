#!/usr/bin/env python3
"""Compare two Step 17 JSON measurement files from the SAME host/conditions."""
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
import statistics


def aggregate(record: dict) -> dict:
    grouped: dict[str, list] = defaultdict(list)
    for row in record["cases"]:
        grouped[row["route"]].append(row)
    return {route: {
        "rps": statistics.median(item["rps"] for item in rows),
        "p50_ms": statistics.median(item["p50_ms"] for item in rows),
        "p99_ms": statistics.median(item["p99_ms"] for item in rows),
        "runs": len(rows),
    } for route, rows in grouped.items()}


def delta(old: float, new: float) -> float:
    return (new / old - 1.0) * 100 if old else float("nan")


def generate(old: dict, new: dict) -> str:
    a, b = aggregate(old), aggregate(new)
    if old.get("arch") != new.get("arch"):
        raise ValueError("different architectures; compare separately")
    if old.get("measurement") != new.get("measurement"):
        raise ValueError("different client methodology")
    if old.get("settings") != new.get("settings"):
        raise ValueError("different counts/repeats")
    if set(a) != set(b):
        raise ValueError("different tested routes")
    lines = ["# Step 17 paired comparison", "",
             f"- Old: `{old['label']}` ({old['git_head']})",
             f"- New: `{new['label']}` ({new['git_head']})",
             f"- Architecture: `{new['arch']}`", "",
             "Client-limited serial HTTP benchmark: **not** peak throughput.",
             "Compare only same-host, same-build-flags runs under similar load.",
             "", "| Route | Old RPS | New RPS | RPS change | Old p99 ms | New p99 ms | p99 change |", 
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for route in sorted(a):
        x, y = a[route], b[route]
        lines.append(f"| {route} | {x['rps']:.1f} | {y['rps']:.1f} | "
                     f"{delta(x['rps'], y['rps']):+.1f}% | {x['p99_ms']:.3f} | "
                     f"{y['p99_ms']:.3f} | {delta(x['p99_ms'], y['p99_ms']):+.1f}% |")
    def high_water(record: dict):
        return max((s.get("hwm_kib", 0) for s in record["checkpoints"].values()), default=0)
    lines += ["", "## Footprint", "",
              f"- Binary size: {old['binary_bytes']} -> {new['binary_bytes']} bytes "
              f"({delta(old['binary_bytes'], new['binary_bytes']):+.1f}%)",
              f"- High-water RSS: {high_water(old)} -> {high_water(new)} KiB",
              "", "## Release decision", "",
              "Any repeatable >5% representative-GET RPS regression requires investigation;",
              ">10% requires explicit acceptance or remediation. These are investigation",
              "thresholds, not an automatic release guarantee. Client-side noise and",
              "security changes must be considered before accepting conclusions.", ""]
    return "\n".join(lines)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("old", type=Path)
    p.add_argument("new", type=Path)
    p.add_argument("--out", type=Path, default=Path("docs/performance/step17-comparison.md"))
    args = p.parse_args()
    old = json.loads(args.old.read_text(encoding="utf-8"))
    new = json.loads(args.new.read_text(encoding="utf-8"))
    result = generate(old, new)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(result, encoding="utf-8")
    print(result)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError) as exc:
        raise SystemExit(f"Comparison unavailable: {exc}") from exc
