#!/usr/bin/env bash
# Step 7: localhost-only exception disclosure regressions.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-docs/modernization/step7-results}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
SERVER_PID=""
SYNC_PID=""
cleanup() {
  if [[ -n "$SYNC_PID" ]]; then
    kill "$SYNC_PID" 2>/dev/null || true
    wait "$SYNC_PID" 2>/dev/null || true
    SYNC_PID=""
  fi
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}
trap cleanup EXIT INT TERM
for cmd in nim python3 ss; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 2; }
done
if ss -H -ltn 'sport = :5483 or sport = :5484' | grep -q .; then
  echo 'Port 5483 or 5484 is in use.' >&2
  exit 2
fi
nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git status --short > "$OUT/git-status.txt"
for mode in debug release; do
  FLAGS=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then FLAGS+=(-d:release); fi
  nim c -r "${FLAGS[@]}" \
    --out:"$OUT/step7_unit_$mode" \
    tests/http/step7_unit.nim > "$OUT/unit-$mode.log" 2>&1 || {
      cat "$OUT/unit-$mode.log" >&2
      exit 1
    }
  nim c "${FLAGS[@]}" \
    --out:"$OUT/step7_server_$mode" \
    tests/http/step7_server.nim > "$OUT/build-$mode.log" 2>&1 || {
      cat "$OUT/build-$mode.log" >&2
      exit 1
    }
  nim c "${FLAGS[@]}" \
    --out:"$OUT/step7_sync_server_$mode" \
    tests/http/step7_sync_server.nim > "$OUT/build-sync-$mode.log" 2>&1 || {
      cat "$OUT/build-sync-$mode.log" >&2
      exit 1
    }
  "$OUT/step7_server_$mode" > "$OUT/server-$mode.log" 2>&1 &
  SERVER_PID=$!
  READY=0
  for _ in $(seq 1 40); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      cat "$OUT/server-$mode.log" >&2
      exit 1
    fi
    if ss -H -ltn 'sport = :5483' | grep -q '127.0.0.1:5483'; then
      READY=1
      break
    fi
    sleep 0.1
  done
  if [[ "$READY" != 1 ]]; then
    echo "Server not ready: $mode" >&2
    cat "$OUT/server-$mode.log" >&2
    exit 1
  fi
  "$OUT/step7_sync_server_$mode" > "$OUT/server-sync-$mode.log" 2>&1 &
  SYNC_PID=$!
  READY=0
  for _ in $(seq 1 40); do
    if ! kill -0 "$SYNC_PID" 2>/dev/null; then
      cat "$OUT/server-sync-$mode.log" >&2
      exit 1
    fi
    if ss -H -ltn 'sport = :5484' | grep -q '127.0.0.1:5484'; then
      READY=1
      break
    fi
    sleep 0.1
  done
  if [[ "$READY" != 1 ]]; then
    echo "Synchronous server not ready: $mode" >&2
    exit 1
  fi
  python3 tests/http/step7_probe.py "$OUT" "$mode" || {
    cat "$OUT/server-$mode.log" >&2
    exit 1
  }
  cleanup
  sleep 0.1
done
python3 - "$OUT" <<'PYREPORT'
import json, sys
from pathlib import Path
out = Path(sys.argv[1]); runs = [json.loads((out / f'step7-{m}.json').read_text())
                                  for m in ('debug', 'release')]
lines = ['# Step 7 exception disclosure regression', '',
         'Loopback only; both Nim ORC debug and release builds.', '']
for run in runs:
    lines += [f"## {run['mode']}: {run['passed']}/{run['total']} PASS", '',
              '| Test | HTTP | Expected | Result |', '| --- | ---: | ---: | --- |']
    for r in run['results']:
        lines.append(f"| {r['test']} | {r['status']} | {r['expected']} | {r['result']} |")
    lines.append('')
(out / 'REPORT.md').write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
PYREPORT
