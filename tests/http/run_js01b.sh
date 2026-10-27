#!/usr/bin/env bash
# JS-01b: router extend macro regression (Linux, Nim 2.2.x / ORC).
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT="${1:-/tmp/jestersimple_js01b}"
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
  command -v "$tool" >/dev/null || {
    echo "Missing dependency: $tool" >&2
    exit 2
  }
done

nim --version > "$OUT/nim-version.txt"
python3 --version > "$OUT/python-version.txt" 2>&1
git rev-parse HEAD > "$OUT/git-head.txt"
git branch --show-current > "$OUT/git-branch.txt"
git status --short > "$OUT/git-status.txt"
python3 -m py_compile tests/http/js01b_probe.py

for matcher in single multi async; do
  for mode in debug release; do
    flags=(--mm:orc --hints:off --path:.)
    case "$matcher" in
      multi) flags+=(-d:js01bMulti) ;;
      async) flags+=(-d:js01bAsync) ;;
    esac
    if [[ "$mode" == release ]]; then flags+=(-d:release); fi

    binary="$OUT/js01b_server_${matcher}_${mode}"
    if ! nim c "${flags[@]}" --out:"$binary" tests/http/js01b_server.nim \
        > "$OUT/build-${matcher}-${mode}.log" 2>&1; then
      tail -n 80 "$OUT/build-${matcher}-${mode}.log" >&2
      exit 1
    fi

    # Use a separate ephemeral loopback port for each server. Avoid the
    # TIME_WAIT false positives of checking a fixed port without SO_REUSEADDR.
    port="$(python3 - <<'PYPORT'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PYPORT
)"
    JS01B_PORT="$port" "$binary" > "$OUT/server-${matcher}-${mode}.log" 2>&1 &
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
        conn = http.client.HTTPConnection('127.0.0.1', port, timeout=.4)
        conn.request('GET', '/implicit', headers={'Connection': 'close'})
        response = conn.getresponse()
        ok = response.status == 200 and response.read() == b'implicit-ok'
        conn.close()
        if ok:
            sys.exit(0)
    except (OSError, TimeoutError, http.client.HTTPException):
        pass
    time.sleep(.1)
raise SystemExit('JS-01b server not ready')
PYREADY
    then
      tail -n 80 "$OUT/server-${matcher}-${mode}.log" >&2
      exit 1
    fi

    if ! python3 tests/http/js01b_probe.py --port "$port" \
        --out "$OUT" --mode "$mode" --matcher "$matcher"; then
      tail -n 80 "$OUT/server-${matcher}-${mode}.log" >&2
      exit 1
    fi
    cleanup
  done
done

# Re-run the existing JS-01 suite after removing its empty-prefix workaround,
# followed by the existing project regression gates.
if [[ "${JS01B_SKIP_EXISTING:-0}" != 1 ]]; then
  for tool in nimble ss; do
    command -v "$tool" >/dev/null || {
      echo "Missing dependency for existing suites: $tool" >&2
      exit 2
    }
  done

  echo '=== Existing gate: JS-01 (48 cases) ==='
  if JS01_SKIP_EXISTING=1 bash tests/http/run_js01.sh "$OUT/existing-js01" \
      > "$OUT/existing-js01.log" 2>&1; then
    printf 'PASS\n' > "$OUT/existing-js01.status"
  else
    printf 'FAIL\n' > "$OUT/existing-js01.status"
    tail -n 60 "$OUT/existing-js01.log" >&2
    exit 1
  fi

  while IFS='|' read -r name command; do
    echo "=== Existing gate: $name ==="
    if bash -c "$command" > "$OUT/existing-$name.log" 2>&1; then
      printf 'PASS\n' > "$OUT/existing-$name.status"
    else
      printf 'FAIL\n' > "$OUT/existing-$name.status"
      tail -n 60 "$OUT/existing-$name.log" >&2
      exit 1
    fi
  done <<GATES
core|nimble test -y
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
    '# JS-01b router extend regression', '',
    'Covers implicit/explicit empty prefixes, nonempty prefixes,',
    'nested extension, and three matcher configurations.', '',
    '| Matcher | Build | Passed | Total |',
    '| --- | --- | ---: | ---: |',
]
for matcher in ('single', 'multi', 'async'):
    for mode in ('debug', 'release'):
        tests = json.loads((out / f'js01b-{matcher}-{mode}.json').read_text())['tests']
        passed = sum(t['result'] == 'PASS' for t in tests)
        lines.append(f'| {matcher} | {mode} | {passed} | {len(tests)} |')
lines += ['', '## Existing regressions', '', '| Gate | Status |', '| --- | --- |']
for name in ('js01', 'core', 'step14', 'step15', 'step16'):
    status = out / f'existing-{name}.status'
    value = status.read_text().strip() if status.exists() else 'NOT RUN'
    lines.append(f'| {name} | {value} |')
lines += ['', 'Source branch, HEAD, and working-tree status are saved separately.', '']
(out / 'REPORT.md').write_text('\n'.join(lines), encoding='utf-8')
print(f'JS-01b report: {out / "REPORT.md"}')
PYREPORT
