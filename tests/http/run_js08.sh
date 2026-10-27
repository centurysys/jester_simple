#!/usr/bin/env bash
# JS-08 allowedHosts policy regression and origin integration checks.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-/tmp/jestersimple_js08}"
mkdir -p -- "$OUT"
OUT="$(realpath "$OUT")"

for tool in nim python3 git; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 2; }
done
nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git branch --show-current > "$OUT/git-branch.txt"
git status --short > "$OUT/git-status.txt"

server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}
trap cleanup EXIT INT TERM

for mode in debug release; do
  flags=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then flags+=(-d:release); fi

  if ! nim c -r "${flags[@]}" --out:"$OUT/js08_unit_$mode" \
      tests/http/js08_unit.nim > "$OUT/unit-$mode.log" 2>&1; then
    tail -n 120 "$OUT/unit-$mode.log" >&2
    exit 1
  fi
  if ! nim c "${flags[@]}" --out:"$OUT/js08_server_$mode" \
      tests/http/js08_server.nim > "$OUT/build-$mode.log" 2>&1; then
    tail -n 120 "$OUT/build-$mode.log" >&2
    exit 1
  fi

  for policy in strict default public; do
    # Loopback ephemeral port; each fixture starts and stops independently.
    port="$(python3 - <<'PYPORT'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PYPORT
)"
    JS08_POLICY="$policy" JS08_PORT="$port" "$OUT/js08_server_$mode" \
      > "$OUT/server-$mode-$policy.log" 2>&1 &
    server_pid="$!"
    if ! python3 tests/http/js08_probe.py "$OUT" "$mode" "$policy" "$port"; then
      tail -n 120 "$OUT/server-$mode-$policy.log" >&2
      exit 1
    fi
    cleanup
  done
done

if [[ "${JS08_SKIP_EXISTING:-0}" != 1 ]]; then
  command -v nimble >/dev/null || { echo 'Missing: nimble' >&2; exit 2; }
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
step9|bash tests/http/run_step9.sh '$OUT/existing-step9'
js01|JS01_SKIP_EXISTING=1 bash tests/http/run_js01.sh '$OUT/existing-js01'
js01b|JS01B_SKIP_EXISTING=1 bash tests/http/run_js01b.sh '$OUT/existing-js01b'
js02|JS02_SKIP_EXISTING=1 bash tests/http/run_js02.sh '$OUT/existing-js02'
js03|JS03_SKIP_EXISTING=1 bash tests/http/run_js03.sh '$OUT/existing-js03'
js04|JS04_SKIP_EXISTING=1 bash tests/http/run_js04.sh '$OUT/existing-js04'
js05|JS05_SKIP_EXISTING=1 bash tests/http/run_js05.sh '$OUT/existing-js05'
js06|JS06_SKIP_EXISTING=1 bash tests/http/run_js06.sh '$OUT/existing-js06'
js07|JS07_SKIP_EXISTING=1 bash tests/http/run_js07.sh '$OUT/existing-js07'
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
    '# JS-08 allowedHosts closed-set regression', '',
    'A nonempty allowedHosts restricts derived origin metadata, not HTTP admission.',
    '', '| Build | Strict | Default | Public base | Unit |',
    '| --- | ---: | ---: | ---: | --- |',
]
for mode in ('debug', 'release'):
    counts = []
    for policy in ('strict', 'default', 'public'):
        record = json.loads((out / f'js08-{mode}-{policy}.json').read_text())
        counts.append(f'{record["passed"]}/{record["total"]}')
    lines.append(f'| {mode} | {counts[0]} | {counts[1]} | {counts[2]} | PASS |')
lines += ['', '## Existing regression gates', '',
          '| Gate | Status |', '| --- | --- |']
for name in ('core', 'step9', 'js01', 'js01b', 'js02', 'js03',
             'js04', 'js05', 'js06', 'js07', 'step14', 'step15', 'step16'):
    status = out / f'existing-{name}.status'
    lines.append(f'| {name} | {status.read_text().strip() if status.exists() else "NOT RUN"} |')
lines += ['', 'Nim 2.2.12 / ORC Debug and Release; loopback-only HTTP fixtures.',
          'Generated binaries and logs are not source files.', '']
report = '\n'.join(lines)
(out / 'REPORT.md').write_text(report, encoding='utf-8')
print(report)
PYREPORT
