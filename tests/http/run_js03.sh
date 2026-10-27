#!/usr/bin/env bash
# JS-03: Protocol Upgrade response-state tests; use loopback only.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-/tmp/jestersimple_js03}"
mkdir -p -- "$OUT"
OUT="$(realpath "$OUT")"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for tool in nim python3 git; do
  command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 2; }
done
nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git branch --show-current > "$OUT/git-branch.txt"
git status --short > "$OUT/git-status.txt"
python3 -m py_compile tests/http/js03_probe.py

for mode in debug release; do
  flags=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then flags+=(-d:release); fi
  binary="$OUT/js03_server_$mode"
  if ! nim c "${flags[@]}" --out:"$binary" tests/http/js03_server.nim \
      > "$OUT/build-$mode.log" 2>&1; then
    tail -n 100 "$OUT/build-$mode.log" >&2
    exit 1
  fi
  port="$(python3 - <<'PYPORT'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PYPORT
)"
  JS03_PORT="$port" "$binary" > "$OUT/server-$mode.log" 2>&1 &
  SERVER_PID="$!"
  if ! python3 - "$SERVER_PID" "$port" <<'PYREADY'
import os, socket, sys, time
pid, port = int(sys.argv[1]), int(sys.argv[2])
for _ in range(70):
    try:
        os.kill(pid, 0)
        with socket.create_connection(('127.0.0.1', port), timeout=.3):
            sys.exit(0)
    except OSError:
        time.sleep(.1)
raise SystemExit('JS-03 server not ready')
PYREADY
  then
    tail -n 80 "$OUT/server-$mode.log" >&2
    exit 1
  fi
  if ! python3 tests/http/js03_probe.py --mode "$mode" --port "$port" --out "$OUT"; then
    tail -n 80 "$OUT/server-$mode.log" >&2
    exit 1
  fi
  cleanup
done

if [[ "${JS03_SKIP_EXISTING:-0}" != 1 ]]; then
  for tool in nimble ss; do
    command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 2; }
  done
  while IFS='|' read -r name command; do
    echo "=== Existing gate: $name ==="
    if bash -c "$command" > "$OUT/existing-$name.log" 2>&1; then
      printf 'PASS\n' > "$OUT/existing-$name.status"
    else
      printf 'FAIL\n' > "$OUT/existing-$name.status"
      tail -n 70 "$OUT/existing-$name.log" >&2
      exit 1
    fi
  done <<GATES
core|nimble test -y
js01|JS01_SKIP_EXISTING=1 bash tests/http/run_js01.sh '$OUT/existing-js01'
js01b|JS01B_SKIP_EXISTING=1 bash tests/http/run_js01b.sh '$OUT/existing-js01b'
js02|JS02_SKIP_EXISTING=1 bash tests/http/run_js02.sh '$OUT/existing-js02'
step14|bash tests/http/run_step14.sh '$OUT/existing-step14'
step15|bash tests/http/run_step15.sh '$OUT/existing-step15'
step16|bash tests/integration/run_step16.sh '$OUT/existing-step16'
GATES
fi

python3 - "$OUT" <<'PYREPORT'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
lines = [
    '# JS-03 HTTP Upgrade response-state regression', '',
    'Synthetic 101 tests only; RFC 6455 is outside this step.', '',
    '| Build | Passed | Total |', '| --- | ---: | ---: |',
]
for mode in ('debug', 'release'):
    data = json.loads((out / f'js03-{mode}.json').read_text())
    passed = sum(t['result'] == 'PASS' for t in data['tests'])
    lines.append(f'| {mode} | {passed} | {len(data["tests"])} |')
lines += ['', '## Existing gates', '', '| Gate | Status |', '| --- | --- |']
for name in ('core', 'js01', 'js01b', 'js02', 'step14', 'step15', 'step16'):
    p = out / f'existing-{name}.status'
    lines.append(f'| {name} | {p.read_text().strip() if p.exists() else "NOT RUN"} |')
lines += ['', 'Do not commit temporary binaries or server logs.', '']
(out / 'REPORT.md').write_text('\n'.join(lines), encoding='utf-8')
print(f'JS-03 report: {out / "REPORT.md"}')
PYREPORT
