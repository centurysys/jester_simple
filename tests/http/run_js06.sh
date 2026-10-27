#!/usr/bin/env bash
# JS-06: bounded static streaming, response-start deadline, RSS/ORC measurements.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-/tmp/jestersimple_js06}"
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
  command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 2; }
done
nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git branch --show-current > "$OUT/git-branch.txt"
git status --short > "$OUT/git-status.txt"
python3 -m py_compile tests/http/js06_probe.py

# Static files are test fixtures in the output directory, never the repository.
STATIC_DIR="$OUT/public"
mkdir -p "$STATIC_DIR"
python3 - "$STATIC_DIR" <<'PYFIXTURES'
import os
import sys
from pathlib import Path
root = Path(sys.argv[1])
for name, length in (("small.bin", 1024 * 1024),
                     ("large.bin", 8 * 1024 * 1024)):
    path = root / name
    with path.open("wb") as f:
        for _ in range(length // 16384):
            f.write(b"a" * 16384)
    os.chmod(path, 0o644)
PYFIXTURES

for mode in debug release; do
  flags=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then flags+=(-d:release); fi

  if ! nim c -r "${flags[@]}" --out:"$OUT/js06_unit_$mode" \
      tests/http/js06_unit.nim > "$OUT/unit-$mode.log" 2>&1; then
    tail -n 100 "$OUT/unit-$mode.log" >&2
    exit 1
  fi

  binary="$OUT/js06_server_$mode"
  if ! nim c "${flags[@]}" --out:"$binary" tests/http/js06_server.nim \
      > "$OUT/build-$mode.log" 2>&1; then
    tail -n 100 "$OUT/build-$mode.log" >&2
    exit 1
  fi

  port="$(python3 - <<'PYPORT'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PYPORT
)"
  JS06_PORT="$port" JS06_PUBLIC_DIR="$STATIC_DIR" "$binary" \
      > "$OUT/server-$mode.log" 2>&1 &
  SERVER_PID="$!"

  if ! python3 - "$SERVER_PID" "$port" <<'PYREADY'
import os, socket, sys, time
pid, port = int(sys.argv[1]), int(sys.argv[2])
for _ in range(70):
    try:
        os.kill(pid, 0)
        with socket.create_connection(('127.0.0.1', port), timeout=0.25):
            sys.exit(0)
    except OSError:
        time.sleep(0.1)
raise SystemExit('JS-06 server did not become ready')
PYREADY
  then
    tail -n 100 "$OUT/server-$mode.log" >&2
    exit 1
  fi
  sleep 0.2  # Give the maxConnections=1 readiness probe time to retire.

  if ! python3 tests/http/js06_probe.py --port "$port" \
      --pid "$SERVER_PID" --mode "$mode" --out "$OUT"; then
    tail -n 100 "$OUT/server-$mode.log" >&2
    exit 1
  fi
  cleanup
done

if [[ "${JS06_SKIP_EXISTING:-0}" != 1 ]]; then
  for tool in nimble ss; do
    command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 2; }
  done
  while IFS='|' read -r name command; do
    echo "=== Existing gate: $name ==="
    if bash -c "$command" > "$OUT/existing-$name.log" 2>&1; then
      echo PASS > "$OUT/existing-$name.status"
    else
      echo FAIL > "$OUT/existing-$name.status"
      tail -n 100 "$OUT/existing-$name.log" >&2
      exit 1
    fi
  done <<GATES
core|nimble test -y
js01|JS01_SKIP_EXISTING=1 bash tests/http/run_js01.sh '$OUT/existing-js01'
js01b|JS01B_SKIP_EXISTING=1 bash tests/http/run_js01b.sh '$OUT/existing-js01b'
js02|JS02_SKIP_EXISTING=1 bash tests/http/run_js02.sh '$OUT/existing-js02'
js03|JS03_SKIP_EXISTING=1 bash tests/http/run_js03.sh '$OUT/existing-js03'
js04|JS04_SKIP_EXISTING=1 bash tests/http/run_js04.sh '$OUT/existing-js04'
js05|JS05_SKIP_EXISTING=1 bash tests/http/run_js05.sh '$OUT/existing-js05'
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
    '# JS-06 HTTP stream, route-start and memory regression', '',
    'Limits used in tests: Managed send 400ms, response start 350ms,',
    'total stream 1200ms. Upgrade is exempt from HTTP startup deadline.', '',
    '| Build | Passed | Total | Unit |',
    '| --- | ---: | ---: | --- |',
]
for mode in ('debug', 'release'):
    data = json.loads((out / f'js06-{mode}.json').read_text())
    count = sum(item['result'] == 'PASS' for item in data['tests'])
    unit = (out / f'unit-{mode}.log').read_text()
    ok = 'JS-06 settings unit tests PASS' in unit
    lines.append(f'| {mode} | {count} | {len(data["tests"])} | {"PASS" if ok else "FAIL"} |')
lines += ['', '## Existing regression gates', '', '| Gate | Status |', '| --- | --- |']
for name in ('core', 'js01', 'js01b', 'js02', 'js03', 'js04', 'js05',
             'step14', 'step15', 'step16'):
    path = out / f'existing-{name}.status'
    lines.append(f'| {name} | {path.read_text().strip() if path.exists() else "NOT RUN"} |')
lines += [
    '', '## Notes', '',
    '- The /collect endpoint calls GC_runOrc only if exposed by the compiler.',
    '- RSS/VmHWM are observations, not leak verdicts or proof of OS page return.',
    '- Closing a timed-out route does not cancel its application Future.',
    '- Do not commit output binaries, logs, test fixtures or JSON observations.',
    ''
]
(out / 'REPORT.md').write_text('\n'.join(lines), encoding='utf-8')
PYREPORT
cat "$OUT/REPORT.md"
