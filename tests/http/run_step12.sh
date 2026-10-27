#!/usr/bin/env bash
# Step 12: bounded raw response sends, loopback only.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-docs/modernization/step12-results}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
PID=""
SYNC_PID=""
cleanup() {
  for pid in "$PID" "$SYNC_PID"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  PID=""
  SYNC_PID=""
}
trap cleanup EXIT INT TERM
for cmd in nim python3 ss; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 2; }
done
if ss -H -ltn 'sport = :5492 or sport = :5493' | grep -q .; then
  echo 'Step 12 ports 5492/5493 are in use' >&2
  exit 2
fi
nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git status --short > "$OUT/git-status.txt"
for mode in debug release; do
  FLAGS=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then FLAGS+=(-d:release); fi
  for role in step12_server step12_sync_server; do
    nim c "${FLAGS[@]}" --out:"$OUT/${role}_$mode"       "tests/http/${role}.nim" > "$OUT/build-${role}-${mode}.log" 2>&1 || {
      cat "$OUT/build-${role}-${mode}.log" >&2
      exit 1
    }
  done
  "$OUT/step12_server_$mode" > "$OUT/server-${mode}.log" 2>&1 &
  PID="$!"
  "$OUT/step12_sync_server_$mode" > "$OUT/server-sync-${mode}.log" 2>&1 &
  SYNC_PID="$!"
  for port in 5492 5493; do
    READY=0
    for _ in $(seq 1 50); do
      if ! kill -0 "$PID" 2>/dev/null || ! kill -0 "$SYNC_PID" 2>/dev/null; then
        echo "Step 12 server exited ($mode)" >&2
        cat "$OUT/server-${mode}.log" "$OUT/server-sync-${mode}.log" >&2
        exit 1
      fi
      if ss -H -ltn "sport = :$port" | grep -q "127.0.0.1:$port"; then
        READY=1
        break
      fi
      sleep 0.1
    done
    if [[ "$READY" != 1 ]]; then
      echo "Step 12 server not ready on $port ($mode)" >&2
      exit 1
    fi
  done
  python3 tests/http/step12_probe.py "$OUT" "$mode" "$PID" || {
    cat "$OUT/server-${mode}.log" "$OUT/server-sync-${mode}.log" >&2
    exit 1
  }
  cleanup
  sleep 0.1
done
python3 - "$OUT" <<'PYREPORT'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
lines = ['# Step 12 raw output and Future management regression', '',
         'Localhost only; Nim 2.2.12 with ORC debug/release.', '']
for mode in ('debug', 'release'):
    data = json.loads((out / f'step12-{mode}.json').read_text())
    lines.extend([f"## {mode}: {data['passed']}/{data['total']} PASS", '',
                  '| Test | Expectation | Result |', '| --- | --- | --- |'])
    for case in data['results']:
        lines.append(f"| {case['name']} | {case['expected']} | {case['result']} |")
    lines.append('')
(out / 'REPORT.md').write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
PYREPORT
