#!/usr/bin/env bash
# Step 13: static path containment and pinned FD lifetime, loopback only.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-docs/modernization/step13-results}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
PID=""
FIXTURE_BASE="$(mktemp -d)"
stop_server() {
  if [[ -n "$PID" ]]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
  fi
}
cleanup() {
  stop_server
  if [[ -n "$FIXTURE_BASE" ]]; then
    rm -rf -- "$FIXTURE_BASE"
    FIXTURE_BASE=""
  fi
}
trap cleanup EXIT INT TERM
for cmd in nim python3 ss; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 2; }
done
if ss -H -ltn 'sport = :5494' | grep -q .; then
  echo 'Step 13 port 5494 is in use' >&2
  exit 2
fi
nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git status --short > "$OUT/git-status.txt"
for mode in debug release; do
  FLAGS=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then FLAGS+=(-d:release); fi
  nim c -r "${FLAGS[@]}" --out:"$OUT/step13_unit_$mode" \
    tests/http/step13_unit.nim > "$OUT/unit-$mode.log" 2>&1 || {
      cat "$OUT/unit-$mode.log" >&2; exit 1;
    }
  nim c "${FLAGS[@]}" --out:"$OUT/step13_server_$mode" \
    tests/http/step13_server.nim > "$OUT/build-$mode.log" 2>&1 || {
      cat "$OUT/build-$mode.log" >&2; exit 1;
    }
  ROOT="$FIXTURE_BASE/fixtures-$mode/public"
  mkdir -p "$ROOT"
  STEP13_STATIC_ROOT="$ROOT" "$OUT/step13_server_$mode" \
    > "$OUT/server-$mode.log" 2>&1 &
  PID="$!"
  READY=0
  for _ in $(seq 1 50); do
    if ! kill -0 "$PID" 2>/dev/null; then
      echo "Step 13 server exited ($mode)" >&2
      cat "$OUT/server-$mode.log" >&2
      exit 1
    fi
    if ss -H -ltn 'sport = :5494' | grep -q '127.0.0.1:5494'; then
      READY=1
      break
    fi
    sleep 0.1
  done
  if [[ "$READY" != 1 ]]; then
    echo "Step 13 server not ready ($mode)" >&2
    cat "$OUT/server-$mode.log" >&2
    exit 1
  fi
  python3 tests/http/step13_probe.py "$OUT" "$mode" "$ROOT" "$PID" || {
    cat "$OUT/server-$mode.log" >&2
    exit 1
  }
  stop_server
  sleep 0.1
done
python3 - "$OUT" <<'PYREPORT'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
lines = ['# Step 13 static file containment regression', '',
         'Loopback only; Nim 2.2.12 ORC, debug and release.', '']
for mode in ('debug', 'release'):
    data = json.loads((out / f'step13-{mode}.json').read_text())
    lines.extend([f"## {mode}: {data['passed']}/{data['total']} PASS", '',
                  '| Test | Expectation | Result |', '| --- | --- | --- |'])
    for case in data['results']:
        lines.append(f"| {case['name']} | {case['expected']} | {case['result']} |")
    lines.append('')
(out / 'REPORT.md').write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
PYREPORT
