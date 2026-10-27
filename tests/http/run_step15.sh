#!/usr/bin/env bash
# Step 15: synchronous matcher fast-path semantic parity on loopback.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-docs/modernization/step15-results}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
ROOT="$(mktemp -d)"
PIDS=()
stop_servers() {
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  PIDS=()
}
cleanup() {
  stop_servers
  rm -rf -- "$ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for cmd in nim python3 ss; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 2; }
done
if ss -H -ltn | grep -Eq '127\.0\.0\.1:(5496|5497|5498)([[:space:]]|$)'; then
  echo 'Step 15 loopback ports 5496-5498 are in use' >&2
  exit 2
fi
printf 'step15-static' > "$ROOT/static.txt"
export STEP15_STATIC_ROOT="$ROOT"
nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git status --short > "$OUT/git-status.txt"
for mode in debug release; do
  FLAGS=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then FLAGS+=(-d:release); fi
  nim c "${FLAGS[@]}" --out:"$OUT/sync-single-$mode" \
    tests/http/step15_sync_server.nim > "$OUT/build-sync-single-$mode.log" 2>&1 || {
      cat "$OUT/build-sync-single-$mode.log" >&2; exit 1;
    }
  nim c "${FLAGS[@]}" -d:step15Multi --out:"$OUT/sync-multiple-$mode" \
    tests/http/step15_sync_server.nim > "$OUT/build-sync-multiple-$mode.log" 2>&1 || {
      cat "$OUT/build-sync-multiple-$mode.log" >&2; exit 1;
    }
  nim c "${FLAGS[@]}" --out:"$OUT/async-single-$mode" \
    tests/http/step15_async_server.nim > "$OUT/build-async-single-$mode.log" 2>&1 || {
      cat "$OUT/build-async-single-$mode.log" >&2; exit 1;
    }
  for role in sync-single sync-multiple async-single; do
    "$OUT/$role-$mode" > "$OUT/server-$role-$mode.log" 2>&1 &
    PIDS+=("$!")
  done
  for port in 5496 5497 5498; do
    READY=0
    for _ in $(seq 1 60); do
      for pid in "${PIDS[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
          echo "Step 15 server exited: $mode" >&2
          cat "$OUT"/server-*"$mode".log >&2
          exit 1
        fi
      done
      if ss -H -ltn "sport = :$port" | grep -q "127.0.0.1:$port"; then
        READY=1
        break
      fi
      sleep 0.1
    done
    if [[ "$READY" != 1 ]]; then
      echo "Step 15 server not ready: $port ($mode)" >&2
      cat "$OUT"/server-*"$mode".log >&2
      exit 1
    fi
  done
  python3 tests/http/step15_probe.py "$OUT" "$mode" || {
    cat "$OUT"/server-*"$mode".log >&2
    exit 1
  }
  stop_servers
  sleep 0.1
done
python3 - "$OUT" <<'PYREPORT'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
lines = ['# Step 15 synchronous fast path parity', '',
         'Loopback-only Debug and Release checks. Timing is informational,',
         'not a before/after throughput benchmark.', '']
for mode in ('debug', 'release'):
    data = json.loads((out / f'step15-{mode}.json').read_text())
    lines += [f"## {mode}: {data['passed']}/{data['total']} PASS", '',
              '| Test | Result |', '| --- | --- |']
    for case in data['results']:
        lines.append(f"| {case['name']} | {'PASS' if case['passed'] else 'FAIL'} |")
    lines += ['', 'Sequential keep-alive timings (300 measured requests each):', '']
    for name, timing in data['timings'].items():
        lines.append(f"- {name}: median {timing['median_ms']} ms; p95 {timing['p95_ms']} ms")
    lines += ['']
(out / 'REPORT.md').write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
PYREPORT
