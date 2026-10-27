#!/usr/bin/env bash
# JS-09: static hidden-path policy and explicit sendFile compatibility.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-/tmp/jestersimple_js09}"
mkdir -p -- "$OUT"
OUT="$(realpath "$OUT")"

for tool in nim python3 git; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 2; }
done
nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git branch --show-current > "$OUT/git-branch.txt"
git status --short > "$OUT/git-status.txt"

FIXTURES="$(mktemp -d)"
server_pid=""
cleanup_server() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}
cleanup() {
  cleanup_server
  rm -rf -- "$FIXTURES"
}
trap cleanup EXIT INT TERM

for mode in debug release; do
  flags=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then flags+=(-d:release); fi
  root="$FIXTURES/$mode/public"
  private="$FIXTURES/$mode/private/.secret-export"
  python3 tests/http/js09_probe.py setup "$root" "$private"

  if ! JS09_STATIC_ROOT="$root" JS09_EXPLICIT_FILE="$private" \
    nim c -r "${flags[@]}" --out:"$OUT/js09_unit_$mode" \
      tests/http/js09_unit.nim > "$OUT/unit-$mode.log" 2>&1; then
    tail -n 120 "$OUT/unit-$mode.log" >&2
    exit 1
  fi

  if ! nim c "${flags[@]}" --out:"$OUT/js09_server_$mode" \
    tests/http/js09_server.nim > "$OUT/build-$mode.log" 2>&1; then
    tail -n 120 "$OUT/build-$mode.log" >&2
    exit 1
  fi

  port="$(python3 - <<'PYPORT'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PYPORT
)"
  JS09_STATIC_ROOT="$root" JS09_EXPLICIT_FILE="$private" JS09_PORT="$port" \
    "$OUT/js09_server_$mode" > "$OUT/server-$mode.log" 2>&1 &
  server_pid="$!"
  if ! python3 tests/http/js09_probe.py run "$OUT" "$mode" "$port" "$server_pid"; then
    tail -n 120 "$OUT/server-$mode.log" >&2
    exit 1
  fi
  cleanup_server
done

if [[ "${JS09_SKIP_EXISTING:-0}" != 1 ]]; then
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
step16|bash tests/integration/run_step16.sh '$OUT/existing-step16'
GATES
fi

python3 - "$OUT" <<'PYREPORT'
import json
import sys
from pathlib import Path

out = Path(sys.argv[1])
lines = [
    '# JS-09 static URL dotfile policy and explicit sendFile regression', '',
    'Hidden URL components return 404; sendFile retains application-selected paths.',
    'Dotfile policy includes .well-known; extension-based filtering is not used.',
    '', '| Build | HTTP integration | Resolver unit |',
    '| --- | ---: | --- |',
]
for mode in ('debug', 'release'):
    record = json.loads((out / f'js09-{mode}.json').read_text())
    lines.append(f'| {mode} | {record["passed"]}/{record["total"]} | PASS |')
lines += ['', '## Existing regression gates', '',
          '| Gate | Status |', '| --- | --- |']
for name in ('core', 'step9', 'step13', 'step14', 'step15',
             'js01', 'js01b', 'js02', 'js03', 'js04', 'js05',
             'js06', 'js07', 'js08', 'step16'):
    status = out / f'existing-{name}.status'
    lines.append(f'| {name} | '
                 f'{status.read_text().strip() if status.exists() else "NOT RUN"} |')
lines += ['', 'Build target: Nim 2.2.12 / ORC on Linux, Debug and Release.',
          'Generated binaries, fixtures and logs are not source files.', '']
report = '\n'.join(lines)
(out / 'REPORT.md').write_text(report, encoding='utf-8')
print(report)
PYREPORT
