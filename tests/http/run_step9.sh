#!/usr/bin/env bash
# Step 9: loopback-only reverse proxy and Host trust regression.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-docs/modernization/step9-results}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  PIDS=()
}
trap cleanup EXIT INT TERM
for cmd in nim python3 ss; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 2; }
done
if ss -H -ltn 'sport = :5487 or sport = :5488 or sport = :5489' | grep -q .; then
  echo 'Step 9 port already in use' >&2
  exit 2
fi
nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git status --short > "$OUT/git-status.txt"
for mode in debug release; do
  FLAGS=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then FLAGS+=(-d:release); fi
  nim c -r "${FLAGS[@]}" --out:"$OUT/step9_unit_$mode" \
    tests/http/step9_unit.nim > "$OUT/unit-$mode.log" 2>&1 || {
    cat "$OUT/unit-$mode.log" >&2
    exit 1
  }
  for name in direct proxy public; do
    nim c "${FLAGS[@]}" --out:"$OUT/step9_${name}_$mode" \
      "tests/http/step9_${name}_server.nim" > "$OUT/build-${name}-$mode.log" 2>&1 || {
        cat "$OUT/build-${name}-$mode.log" >&2
        exit 1
      }
    "$OUT/step9_${name}_$mode" > "$OUT/server-${name}-$mode.log" 2>&1 &
    PIDS+=("$!")
  done
  for port in 5487 5488 5489; do
    READY=0
    for _ in $(seq 1 40); do
      if ss -H -ltn "sport = :$port" | grep -q "127.0.0.1:$port"; then
        READY=1
        break
      fi
      sleep 0.1
    done
    if [[ "$READY" != 1 ]]; then
      echo "Step 9 server not ready on $port ($mode)" >&2
      for name in direct proxy public; do cat "$OUT/server-${name}-$mode.log" >&2; done
      exit 1
    fi
  done
  python3 tests/http/step9_probe.py "$OUT" "$mode" || {
    for name in direct proxy public; do cat "$OUT/server-${name}-$mode.log" >&2; done
    exit 1
  }
  cleanup
  sleep 0.1
done
python3 - "$OUT" <<'PYREPORT'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
lines = ['# Step 9 Host and forwarded origin regression', '',
         'Loopback-only; Nim 2.2.12 ORC debug and release.', '']
for mode in ('debug', 'release'):
    r = json.loads((out / f'step9-{mode}.json').read_text())
    lines += [f"## {mode}: {r['passed']}/{r['total']} PASS", '',
              '| Test | HTTP | Expected | Result |', '| --- | ---: | ---: | --- |']
    for t in r['results']:
        lines.append(f"| {t['test']} | {t['status']} | {t['expected']} | {t['result']} |")
    lines.append('')
(out / 'REPORT.md').write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
PYREPORT
