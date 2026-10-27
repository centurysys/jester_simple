#!/usr/bin/env bash
# Step 16 cross-feature test, without changing the framework implementation.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-docs/modernization/step16-results}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
ROOT="$(mktemp -d)"
SERVER_PID=""
stop_server() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}
cleanup() {
  stop_server
  rm -rf -- "$ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for command_name in nim python3; do
  command -v "$command_name" >/dev/null || {
    echo "Missing command: $command_name" >&2
    exit 2
  }
done
python3 - <<'PYCHECK'
import socket
with socket.socket() as sock:
    try:
        sock.bind(('127.0.0.1', 5499))
    except OSError as exc:
        raise SystemExit(f'Step 16 port 5499 unavailable: {exc}')
PYCHECK
mkdir -p "$ROOT/public"
printf 'step16-static-data' > "$ROOT/public/static.txt"
printf 'step16-secret-file' > "$ROOT/private.txt"
ln -s "$ROOT/private.txt" "$ROOT/public/outside.txt"
export STEP16_STATIC_ROOT="$ROOT/public"
nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git status --short > "$OUT/git-status.txt"
FAILED=0
for mode in debug release; do
  FLAGS=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then
    FLAGS+=(-d:release)
  fi
  if ! nim c "${FLAGS[@]}" --out:"$OUT/step16-$mode" \
    tests/integration/step16_server.nim > "$OUT/build-$mode.log" 2>&1; then
    cat "$OUT/build-$mode.log" >&2
    echo "Step 16 $mode failed to compile" >&2
    exit 1
  fi
  "$OUT/step16-$mode" > "$OUT/server-$mode.log" 2>&1 &
  SERVER_PID="$!"
  if ! python3 - "$SERVER_PID" <<'PYREADY'
import http.client
import os
import sys
import time
pid = int(sys.argv[1])
for _ in range(80):
    try:
        conn = http.client.HTTPConnection('127.0.0.1', 5499, timeout=.4)
        conn.request('GET', '/ping')
        response = conn.getresponse()
        valid = response.status == 200 and response.read() == b'pong'
        conn.close()
        if valid:
            sys.exit(0)
    except (OSError, TimeoutError):
        pass
    time.sleep(.1)
raise SystemExit('Step 16 server failed to become ready')
PYREADY
  then
    tail -n 80 "$OUT/server-$mode.log" >&2
    exit 1
  fi
  if ! python3 tests/integration/step16_probe.py "$OUT" "$mode"; then
    FAILED=1
    tail -n 80 "$OUT/server-$mode.log" >&2
  fi
  stop_server
  sleep 0.1
done
python3 - "$OUT" <<'PYREPORT'
import json
import sys
from pathlib import Path
out = Path(sys.argv[1])
lines = [
    '# Step 16 cross-feature integration', '',
    'Linux loopback-only; Debug and Release compiled with Nim/ORC.',
    'This test is an integration gate, not a formal security proof.', '',
]
for mode in ('debug', 'release'):
    file = out / f'step16-{mode}.json'
    if not file.exists():
        lines += [f'## {mode}: NOT RUN', '']
        continue
    obj = json.loads(file.read_text(encoding='utf-8'))
    lines += [f"## {mode}: {obj['passed']}/{obj['total']} PASS", '',
              '| Cross-feature test | Result |', '| --- | --- |']
    for case in obj['cases']:
        lines.append(f"| {case['name']} | {'PASS' if case['passed'] else 'FAIL'} |")
    lines.append('')
(out / 'REPORT.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
print('\n'.join(lines))
PYREPORT
exit "$FAILED"
