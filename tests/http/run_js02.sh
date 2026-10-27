#!/usr/bin/env bash
# JS-02: Sensitive response header logging regression (Linux/Nim 2.2.x/ORC).
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT="${1:-/tmp/jestersimple_js02}"
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
python3 --version > "$OUT/python-version.txt" 2>&1
git rev-parse HEAD > "$OUT/git-head.txt"
git branch --show-current > "$OUT/git-branch.txt"
git status --short > "$OUT/git-status.txt"
python3 -m py_compile tests/http/js02_probe.py

for mode in debug release; do
  flags=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then flags+=(-d:release); fi
  if ! nim c -r "${flags[@]}" --out:"$OUT/js02_unit_$mode" \
      tests/http/js02_unit.nim > "$OUT/unit-$mode.log" 2>&1; then
    tail -n 80 "$OUT/unit-$mode.log" >&2
    exit 1
  fi

  binary="$OUT/js02_server_$mode"
  if ! nim c "${flags[@]}" --out:"$binary" tests/http/js02_server.nim \
      > "$OUT/build-$mode.log" 2>&1; then
    tail -n 80 "$OUT/build-$mode.log" >&2
    exit 1
  fi

  port="$(python3 - <<'PYPORT'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PYPORT
)"
  JS02_PORT="$port" "$binary" > "$OUT/server-$mode.log" 2>&1 &
  SERVER_PID="$!"

  if ! python3 - "$SERVER_PID" "$port" <<'PYREADY'
import http.client
import os
import sys
import time
pid, port = int(sys.argv[1]), int(sys.argv[2])
for _ in range(70):
    try:
        os.kill(pid, 0)
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=.5)
        connection.request('GET', '/ping', headers={'Connection': 'close'})
        response = connection.getresponse()
        ok = response.status == 200 and response.read() == b'pong'
        connection.close()
        if ok:
            sys.exit(0)
    except (OSError, TimeoutError, http.client.HTTPException):
        pass
    time.sleep(.1)
raise SystemExit('JS-02 server not ready')
PYREADY
  then
    tail -n 80 "$OUT/server-$mode.log" >&2
    exit 1
  fi

  if ! python3 tests/http/js02_probe.py --phase wire --mode "$mode" \
      --port "$port" --out "$OUT"; then
    tail -n 40 "$OUT/server-$mode.log" >&2
    exit 1
  fi
  cleanup
  # Read logs only after terminating the server to avoid buffered output.
  python3 tests/http/js02_probe.py --phase log --mode "$mode" \
    --server-log "$OUT/server-$mode.log" --out "$OUT"
done

if [[ "${JS02_SKIP_EXISTING:-0}" != 1 ]]; then
  for tool in nimble ss; do
    command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 2; }
  done
  while IFS='|' read -r name command; do
    echo "=== Existing gate: $name ==="
    if bash -c "$command" > "$OUT/existing-$name.log" 2>&1; then
      printf 'PASS\n' > "$OUT/existing-$name.status"
    else
      printf 'FAIL\n' > "$OUT/existing-$name.status"
      tail -n 65 "$OUT/existing-$name.log" >&2
      exit 1
    fi
  done <<GATES
core|nimble test -y
js01|JS01_SKIP_EXISTING=1 bash tests/http/run_js01.sh '$OUT/existing-js01'
js01b|JS01B_SKIP_EXISTING=1 bash tests/http/run_js01b.sh '$OUT/existing-js01b'
step14|bash tests/http/run_step14.sh '$OUT/existing-step14'
step15|bash tests/http/run_step15.sh '$OUT/existing-step15'
step16|bash tests/integration/run_step16.sh '$OUT/existing-step16'
GATES
fi

python3 - "$OUT" <<'PYREPORT'
import json
import sys
from pathlib import Path
out = Path(sys.argv[1])
lines = [
    '# JS-02 sensitive header log redaction', '',
    'Response values are checked on the wire; response logs are checked after shutdown.',
    '', '| Build | Wire | Log | Unit |', '| --- | --- | --- | --- |',
]
for mode in ('debug', 'release'):
    report = json.loads((out / f'js02-{mode}.json').read_text())
    wire = 'PASS' if all(x['result'] == 'PASS' for x in report['wire_tests']) else 'FAIL'
    log = report['log_test']['result']
    unit = 'PASS' if 'PASS JS-02' in (out / f'unit-{mode}.log').read_text() else 'FAIL'
    lines.append(f'| {mode} | {wire} | {log} | {unit} |')
lines += ['', '## Existing regression gates', '', '| Gate | Result |', '| --- | --- |']
for name in ('core', 'js01', 'js01b', 'step14', 'step15', 'step16'):
    status = out / f'existing-{name}.status'
    lines.append(f'| {name} | {status.read_text().strip() if status.exists() else "NOT RUN"} |')
lines += ['', 'Do not commit server logs: these are security regression artifacts.', '']
(out / 'REPORT.md').write_text('\n'.join(lines), encoding='utf-8')
print(f'JS-02 report: {out / "REPORT.md"}')
PYREPORT
