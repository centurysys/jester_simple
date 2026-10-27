#!/usr/bin/env bash
# JS-11: startup validation, settings snapshot and FD headroom gates.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$(realpath -m "${1:-/tmp/jestersimple_js11}")"
mkdir -p -- "$OUT"
for tool in nim python3 git; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 2; }
done
nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git branch --show-current > "$OUT/git-branch.txt"
git status --short > "$OUT/git-status.txt"

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}
trap cleanup EXIT INT TERM

for mode in debug release; do
  flags=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then flags+=(-d:release); fi
  for file in js11_unit js11_startup js11_server; do
    if ! nim c "${flags[@]}" --out:"$OUT/${file}_${mode}" \
      "tests/http/${file}.nim" > "$OUT/build-${file}-${mode}.log" 2>&1; then
      tail -n 120 "$OUT/build-${file}-${mode}.log" >&2
      exit 1
    fi
  done
  "$OUT/js11_unit_${mode}" > "$OUT/unit-${mode}.log" 2>&1
  echo PASS > "$OUT/unit-${mode}.status"

  for case_name in static connections timeout body proxy; do
    "$OUT/js11_startup_${mode}" "$case_name" > "$OUT/startup-${case_name}-${mode}.log" 2>&1
    grep -Fq "JS11_STARTUP_REJECTED: $case_name" "$OUT/startup-${case_name}-${mode}.log"
    echo PASS > "$OUT/startup-${case_name}-${mode}.status"
  done

  port="$(python3 - <<'PYPORT'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1', 0))
    print(s.getsockname()[1])
PYPORT
)"
  JS11_PORT="$port" "$OUT/js11_server_${mode}" > "$OUT/server-${mode}.log" 2>&1 &
  server_pid=$!
  if ! python3 tests/http/js11_probe.py --port "$port" --output "$OUT/js11-${mode}.json" \
      > "$OUT/probe-${mode}.log" 2>&1; then
    cat "$OUT/probe-${mode}.log" >&2
    tail -n 100 "$OUT/server-${mode}.log" >&2
    exit 1
  fi
  echo PASS > "$OUT/integration-${mode}.status"
  cleanup
done

if [[ "${JS11_SKIP_EXISTING:-0}" != 1 ]]; then
  command -v nimble >/dev/null || { echo 'Missing: nimble' >&2; exit 2; }
  while IFS='|' read -r name command; do
    echo "=== Regression: $name ==="
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
step13|bash tests/http/run_step13.sh '$OUT/existing-step13'
step14|bash tests/http/run_step14.sh '$OUT/existing-step14'
step15|bash tests/http/run_step15.sh '$OUT/existing-step15'
js01|JS01_SKIP_EXISTING=1 bash tests/http/run_js01.sh '$OUT/existing-js01'
js01b|JS01B_SKIP_EXISTING=1 bash tests/http/run_js01b.sh '$OUT/existing-js01b'
js02|JS02_SKIP_EXISTING=1 bash tests/http/run_js02.sh '$OUT/existing-js02'
js03|JS03_SKIP_EXISTING=1 bash tests/http/run_js03.sh '$OUT/existing-js03'
js04|JS04_SKIP_EXISTING=1 bash tests/http/run_js04.sh '$OUT/existing-js04'
js05|JS05_SKIP_EXISTING=1 bash tests/http/run_js05.sh '$OUT/existing-js05'
js06|JS06_SKIP_EXISTING=1 bash tests/http/run_js06.sh '$OUT/existing-js06'
js07|JS07_SKIP_EXISTING=1 bash tests/http/run_js07.sh '$OUT/existing-js07'
js08|JS08_SKIP_EXISTING=1 bash tests/http/run_js08.sh '$OUT/existing-js08'
js09|JS09_SKIP_EXISTING=1 bash tests/http/run_js09.sh '$OUT/existing-js09'
js10|JS10_SKIP_EXISTING=1 bash tests/http/run_js10.sh '$OUT/existing-js10'
step16|bash tests/integration/run_step16.sh '$OUT/existing-step16'
GATES
fi

python3 - "$OUT" <<'PYREPORT'
from pathlib import Path
import sys
root = Path(sys.argv[1])
def status(filename):
    p = root / filename
    return p.read_text().strip() if p.exists() else 'NOT RUN'
lines = ['# JS-11 settings initialization and FD admission regression', '',
         '| Build | Unit | Startup rejection | Integration |',
         '| --- | --- | --- | --- |']
for mode in ('debug', 'release'):
    startup = '/'.join(status(f'startup-{name}-{mode}.status')
        for name in ('static', 'connections', 'timeout', 'body', 'proxy'))
    lines.append(f'| {mode} | {status(f"unit-{mode}.status")} | {startup} | {status(f"integration-{mode}.status")} |')
lines += ['', '## Existing regression gates', '', '| Gate | Result |', '| --- | --- |']
for name in ('core','step9','step13','step14','step15','js01','js01b','js02','js03',
             'js04','js05','js06','js07','js08','js09','js10','step16'):
    lines.append(f'| {name} | {status(f"existing-{name}.status")} |')
lines += ['', 'FD headroom is tested deterministically as a unit; an OS-level',
          'EMFILE/ENFILE recovery test is not included in this step.',
          'Request initialization errors must produce HTTP 500 without exiting.',
          'Nim 2.2.12 / ORC, Debug and Release. Do not commit test logs or binaries.', '']
text = '\n'.join(lines)
(root/'REPORT.md').write_text(text)
print(text)
PYREPORT
