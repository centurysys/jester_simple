#!/usr/bin/env bash
# JS-04: Upgrade ownership, Connection-token parsing and connection-slot tests.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-/tmp/jestersimple_js04}"
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
python3 -m py_compile tests/http/js04_probe.py

for mode in debug release; do
  flags=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then flags+=(-d:release); fi

  if ! nim c -r "${flags[@]}" --out:"$OUT/js04_unit_$mode" \
      tests/http/js04_unit.nim > "$OUT/unit-$mode.log" 2>&1; then
    tail -n 90 "$OUT/unit-$mode.log" >&2
    exit 1
  fi

  binary="$OUT/js04_server_$mode"
  if ! nim c "${flags[@]}" --out:"$binary" tests/http/js04_server.nim \
      > "$OUT/build-$mode.log" 2>&1; then
    tail -n 90 "$OUT/build-$mode.log" >&2
    exit 1
  fi

  # Choose a free ephemeral port for each run, avoiding a fixed-port TIME_WAIT.
  port="$(python3 - <<'PYPORT'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PYPORT
)"
  JS04_PORT="$port" "$binary" > "$OUT/server-$mode.log" 2>&1 &
  SERVER_PID="$!"

  if ! python3 - "$SERVER_PID" "$port" <<'PYREADY'
import os, socket, sys, time
pid, port = int(sys.argv[1]), int(sys.argv[2])
for _ in range(70):
    try:
        os.kill(pid, 0)
        with socket.create_connection(('127.0.0.1', port), timeout=.25):
            sys.exit(0)
    except OSError:
        time.sleep(.1)
raise SystemExit('JS-04 server did not become ready')
PYREADY
  then
    tail -n 90 "$OUT/server-$mode.log" >&2
    exit 1
  fi
  # Readiness connect has completed; let its transport Future retire.
  sleep 0.1
  if ! python3 tests/http/js04_probe.py --port "$port" --pid "$SERVER_PID" \
      --mode "$mode" --out "$OUT"; then
    tail -n 90 "$OUT/server-$mode.log" >&2
    exit 1
  fi
  cleanup
done

if [[ "${JS04_SKIP_EXISTING:-0}" != 1 ]]; then
  for tool in nimble ss; do
    command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 2; }
  done
  while IFS='|' read -r name command; do
    echo "=== Existing gate: $name ==="
    if bash -c "$command" > "$OUT/existing-$name.log" 2>&1; then
      printf 'PASS\n' > "$OUT/existing-$name.status"
    else
      printf 'FAIL\n' > "$OUT/existing-$name.status"
      tail -n 90 "$OUT/existing-$name.log" >&2
      exit 1
    fi
  done <<GATES
core|nimble test -y
js01|JS01_SKIP_EXISTING=1 bash tests/http/run_js01.sh '$OUT/existing-js01'
js01b|JS01B_SKIP_EXISTING=1 bash tests/http/run_js01b.sh '$OUT/existing-js01b'
js02|JS02_SKIP_EXISTING=1 bash tests/http/run_js02.sh '$OUT/existing-js02'
js03|JS03_SKIP_EXISTING=1 bash tests/http/run_js03.sh '$OUT/existing-js03'
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
    '# JS-04 Upgrade connection lifecycle regression', '',
    'Synthetic 101 only; no RFC 6455 frames or WebSocket handshake.', '',
    '| Build | Connection tests | Unit |', '| --- | ---: | --- |',
]
for mode in ('debug', 'release'):
    data = json.loads((out / f'js04-{mode}.json').read_text())
    count = sum(x['result'] == 'PASS' for x in data['tests'])
    unit = (out / f'unit-{mode}.log').read_text()
    unit_status = 'PASS' if 'JS-04 Connection token unit tests PASS' in unit else 'FAIL'
    lines.append(f'| {mode} | {count}/{len(data["tests"])} | {unit_status} |')
lines += ['', '## Existing regression gates', '', '| Gate | Result |', '| --- | --- |']
for name in ('core', 'js01', 'js01b', 'js02', 'js03',
             'step14', 'step15', 'step16'):
    path = out / f'existing-{name}.status'
    lines.append(f'| {name} | {path.read_text().strip() if path.exists() else "NOT RUN"} |')
lines += ['', 'Server logs and compiled binaries are local artifacts, not source files.', '']
(out / 'REPORT.md').write_text('\n'.join(lines), encoding='utf-8')
print(f'JS-04 report: {out / "REPORT.md"}')
PYREPORT
