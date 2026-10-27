#!/usr/bin/env bash
# JS-12: URI reuse, oversized HTTP lines, and duplicate request headers.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$(realpath -m "${1:-/tmp/jestersimple_js12}")"
mkdir -p -- "$OUT"
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
  if ! nim c "${flags[@]}" --out:"$OUT/js12_server_${mode}" \
    tests/http/js12_server.nim > "$OUT/build-${mode}.log" 2>&1; then
    tail -n 120 "$OUT/build-${mode}.log" >&2
    exit 1
  fi
  port="$(python3 - <<'PYPORT'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1', 0))
    print(s.getsockname()[1])
PYPORT
)"
  JS12_PORT="$port" "$OUT/js12_server_${mode}" > "$OUT/server-${mode}.log" 2>&1 &
  server_pid=$!
  if ! python3 tests/http/js12_probe.py "$OUT" "$mode" "$port" \
      > "$OUT/probe-${mode}.log" 2>&1; then
    cat "$OUT/probe-${mode}.log" >&2
    tail -n 100 "$OUT/server-${mode}.log" >&2
    exit 1
  fi
  echo PASS > "$OUT/js12-${mode}.status"
  cleanup
done

if [[ "${JS12_SKIP_EXISTING:-0}" != 1 ]]; then
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
js11|JS11_SKIP_EXISTING=1 bash tests/http/run_js11.sh '$OUT/existing-js11'
step16|bash tests/integration/run_step16.sh '$OUT/existing-step16'
GATES
fi

python3 - "$OUT" <<'PYREPORT'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
def status(name):
    f = root / name
    return f.read_text().strip() if f.exists() else 'NOT RUN'
lines = [
    '# JS-12 HTTP parser boundary regression', '',
    'Nim 2.2.12 / ORC. Raw keep-alive, line limits, duplicate headers.', '',
    '| Build | Passed | Total |', '| --- | ---: | ---: |',
]
for mode in ('debug', 'release'):
    record = json.loads((root / f'js12-{mode}.json').read_text())
    lines.append(f'| {mode} | {record["passed"]} | {record["total"]} |')
lines += ['', '## Existing regression gates', '', '| Gate | Status |', '| --- | --- |']
for name in ('core', 'step9', 'step13', 'step14', 'step15',
             'js01', 'js01b', 'js02', 'js03', 'js04', 'js05',
             'js06', 'js07', 'js08', 'js09', 'js10', 'js11', 'step16'):
    lines.append(f'| {name} | {status(f"existing-{name}.status")} |')
lines += ['', 'Nim 2.2.12 std/uri.parseUri resets Uri on reuse; the URI tests',
          'are regressions, not evidence of a reproduced stale-field bug.',
          'recvLineInto stops after maxLength is exceeded; reject and close',
          'without attempting to resynchronize the HTTP stream.',
          'Do not commit test logs or compiled binaries.', '']
report = '\n'.join(lines)
(root / 'REPORT.md').write_text(report, encoding='utf-8')
print(report)
PYREPORT
