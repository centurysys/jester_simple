#!/usr/bin/env bash
# Step 10: query/form decoding and URI boundary regression, loopback only.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-docs/modernization/step10-results}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
PID=""
cleanup() {
  if [[ -n "$PID" ]]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
  fi
}
trap cleanup EXIT INT TERM
for cmd in nim python3 ss; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 2; }
done
if ss -H -ltn 'sport = :5490' | grep -q .; then
  echo 'Step 10 port 5490 already in use' >&2
  exit 2
fi
nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git status --short > "$OUT/git-status.txt"
for mode in debug release; do
  FLAGS=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then FLAGS+=(-d:release); fi
  nim c -r "${FLAGS[@]}" --out:"$OUT/step10_unit_$mode" \
    tests/http/step10_unit.nim > "$OUT/unit-$mode.log" 2>&1 || {
    cat "$OUT/unit-$mode.log" >&2
    exit 1
  }
  nim c "${FLAGS[@]}" --out:"$OUT/step10_server_$mode" \
    tests/http/step10_server.nim > "$OUT/build-$mode.log" 2>&1 || {
    cat "$OUT/build-$mode.log" >&2
    exit 1
  }
  "$OUT/step10_server_$mode" > "$OUT/server-$mode.log" 2>&1 &
  PID="$!"
  READY=0
  for _ in $(seq 1 40); do
    if ss -H -ltn 'sport = :5490' | grep -q '127.0.0.1:5490'; then
      READY=1
      break
    fi
    sleep 0.1
  done
  if [[ "$READY" != 1 ]]; then
    echo "Step 10 server not ready ($mode)" >&2
    cat "$OUT/server-$mode.log" >&2
    exit 1
  fi
  python3 tests/http/step10_probe.py "$OUT" "$mode" || {
    cat "$OUT/server-$mode.log" >&2
    exit 1
  }
  cleanup
  sleep 0.1
done
python3 - "$OUT" <<'PYREPORT'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
lines = ['# Step 10 query/form and URI regression', '',
         'Loopback-only; Nim 2.2.12 ORC debug and release.', '']
for mode in ('debug', 'release'):
    report = json.loads((out / f'step10-{mode}.json').read_text())
    lines.extend([f"## {mode}: {report['passed']}/{report['total']} PASS", '',
                  '| Test | HTTP | Expected | Result |',
                  '| --- | ---: | ---: | --- |'])
    for case in report['results']:
        lines.append(f"| {case['name']} | {case['status']} | {case['expected_status']} | {case['result']} |")
    lines.append('')
(out / 'REPORT.md').write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
PYREPORT
