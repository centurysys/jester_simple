#!/usr/bin/env bash
# JS-01: managed HEAD body suppression and HTTP keep-alive regression tests.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-/tmp/jestersimple_js01}"
mkdir -p "$OUT"
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
python3 -m py_compile tests/http/js01_probe.py
# Match the server's SO_REUSEADDR behavior. A plain bind() can return
# EADDRINUSE when only TCP TIME_WAIT sockets remain from an earlier run.
python3 - <<'PYPORT'
import socket
with socket.socket() as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(('127.0.0.1', 5511))
    except OSError as exc:
        raise SystemExit(
            f'JS-01 port 5511 unavailable: {exc}\n'
            "Check the listener with: ss -ltnp '( sport = :5511 )'"
        )
PYPORT

for matcher in single multi async; do
  for mode in debug release; do
    flags=(--mm:orc --hints:off --path:.)
    case "$matcher" in
      multi) flags+=(-d:js01Multi) ;;
      async) flags+=(-d:js01Async) ;;
    esac
    if [[ "$mode" == release ]]; then flags+=(-d:release); fi
    binary="$OUT/js01_server_${matcher}_${mode}"
    if ! nim c "${flags[@]}" --out:"$binary" tests/http/js01_server.nim \
        > "$OUT/build-${matcher}-${mode}.log" 2>&1; then
      cat "$OUT/build-${matcher}-${mode}.log" >&2
      exit 1
    fi

    "$binary" > "$OUT/server-${matcher}-${mode}.log" 2>&1 &
    SERVER_PID="$!"
    if ! python3 - "$SERVER_PID" <<'PYREADY'
import http.client
import os
import sys
import time
pid = int(sys.argv[1])
for _ in range(60):
    try:
        os.kill(pid, 0)
        conn = http.client.HTTPConnection('127.0.0.1', 5511, timeout=.4)
        conn.request('GET', '/ping', headers={'Connection': 'close'})
        response = conn.getresponse()
        ok = response.status == 200 and response.read() == b'pong'
        conn.close()
        if ok:
            sys.exit(0)
    except (OSError, TimeoutError):
        pass
    time.sleep(.1)
raise SystemExit('JS-01 server not ready')
PYREADY
    then
      tail -n 50 "$OUT/server-${matcher}-${mode}.log" >&2
      exit 1
    fi
    if ! python3 tests/http/js01_probe.py --out "$OUT" \
        --mode "$mode" --matcher "$matcher"; then
      tail -n 50 "$OUT/server-${matcher}-${mode}.log" >&2
      exit 1
    fi
    cleanup
    sleep .2
  done
done

# Run regression gates unless explicitly disabled for a quick smoke test.
if [[ "${JS01_SKIP_EXISTING:-0}" != 1 ]]; then
  for tool in nimble ss; do
    command -v "$tool" >/dev/null || {
      echo "Missing dependency for existing suites: $tool" >&2; exit 2;
    }
  done
  while IFS='|' read -r name command; do
    echo "=== Existing gate: $name ==="
    if bash -c "$command" > "$OUT/existing-$name.log" 2>&1; then
      printf 'PASS\n' > "$OUT/existing-$name.status"
    else
      printf 'FAIL\n' > "$OUT/existing-$name.status"
      tail -n 50 "$OUT/existing-$name.log" >&2
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
lines = ['# JS-01 Managed HEAD regression', '',
         'All HEAD checks require no bytes after the header terminator.',
         'GET and HEAD must have the same GET-equivalent Content-Length.', '',
         '| Matcher | Build | Tests passed | Total |',
         '| --- | --- | ---: | ---: |']
for matcher in ('single', 'multi', 'async'):
    for mode in ('debug', 'release'):
        data = json.loads((out / f'js01-{matcher}-{mode}.json').read_text())
        tests = data['tests']
        passed = sum(t['result'] == 'PASS' for t in tests)
        lines.append(f'| {matcher} | {mode} | {passed} | {len(tests)} |')
lines += ['', '## Existing regression gates', '', '| Gate | Status |',
          '| --- | --- |']
for name in ('core', 'step14', 'step15', 'step16'):
    file = out / f'existing-{name}.status'
    lines.append(f'| {name} | {file.read_text().strip() if file.exists() else "NOT RUN"} |')
lines += ['', 'Source branch and HEAD are in git-branch.txt and git-head.txt.', '']
(out / 'REPORT.md').write_text('\n'.join(lines), encoding='utf-8')
print(f'JS-01 report: {out / "REPORT.md"}')
PYREPORT
