#!/usr/bin/env bash
# JS-00: Capture pre-fix control tests, defect observations and existing gates.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-/tmp/jestersimple_js00}"
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
uname -a > "$OUT/kernel.txt"
python3 -m py_compile tests/http/js00_probe.py
python3 - <<'PYCHECK'
import socket
with socket.socket() as sock:
    try:
        sock.bind(('127.0.0.1', 5510))
    except OSError as exc:
        raise SystemExit(f'JS-00 port 5510 unavailable: {exc}')
PYCHECK

FAILED=0
for mode in debug release; do
  flags=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then flags+=(-d:release); fi
  if ! nim c "${flags[@]}" --out:"$OUT/js00_server_$mode" \
      tests/http/js00_server.nim > "$OUT/build-$mode.log" 2>&1; then
    cat "$OUT/build-$mode.log" >&2
    exit 1
  fi
  "$OUT/js00_server_$mode" > "$OUT/server-$mode.log" 2>&1 &
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
        conn = http.client.HTTPConnection('127.0.0.1', 5510, timeout=.4)
        conn.request('GET', '/ping')
        response = conn.getresponse()
        ok = response.status == 200 and response.read() == b'pong'
        conn.close()
        if ok:
            sys.exit(0)
    except (OSError, TimeoutError):
        pass
    time.sleep(.1)
raise SystemExit('JS-00 server not ready')
PYREADY
  then
    tail -n 60 "$OUT/server-$mode.log" >&2
    exit 1
  fi
  if ! python3 tests/http/js00_probe.py --out "$OUT" --mode "$mode" \
      --pid "$SERVER_PID" --server-log "$OUT/server-$mode.log"; then
    FAILED=1
  fi
  cleanup
  sleep .2
done

# Run the existing gates as additional controls. Their failures must be
# reported separately from the defects intentionally reproduced by JS-00.
if [[ "${JS00_SKIP_EXISTING:-0}" != 1 ]]; then
  if ! command -v nimble >/dev/null || ! command -v ss >/dev/null; then
    echo 'Existing regression gates skipped: nimble and ss required' >&2
    printf 'SKIPPED_MISSING_DEPENDENCY\n' > "$OUT/existing-gates.status"
  else
    while IFS='|' read -r name command; do
      echo "=== Existing gate: $name ==="
      if bash -c "$command" > "$OUT/existing-$name.log" 2>&1; then
        printf 'PASS\n' > "$OUT/existing-$name.status"
      else
        FAILED=1
        printf 'FAIL\n' > "$OUT/existing-$name.status"
        tail -n 35 "$OUT/existing-$name.log" >&2
      fi
    done <<GATES
core|nimble test -y
step14|bash tests/http/run_step14.sh '$OUT/existing-step14'
step15|bash tests/http/run_step15.sh '$OUT/existing-step15'
step16|bash tests/integration/run_step16.sh '$OUT/existing-step16'
GATES
  fi
fi

python3 - "$OUT" <<'PYREPORT'
import json
import sys
from pathlib import Path
out = Path(sys.argv[1])
lines = ['# JS-00 baseline report', '',
         'Observed defects are intentionally not treated as control failures.',
         'Upgrade routes simulate transport behavior; no RFC 6455 handshake is claimed.',
         '', '## Source', '',
         f"Git HEAD: `{(out / 'git-head.txt').read_text().strip()}`", '',
         '## Control tests', '', '| Mode | Control | Result |', '| --- | --- | --- |']
for mode in ('debug', 'release'):
    file = out / f'js00-{mode}.json'
    if not file.exists():
        lines.append(f'| {mode} | (not run) | NOT RUN |')
        continue
    record = json.loads(file.read_text())
    for test in record['controls']:
        lines.append(f"| {mode} | {test['name']} | {test['result']} |")
lines += ['', '## Reproduction observations', '',
          '| Mode | Observation | Status |', '| --- | --- | --- |']
for mode in ('debug', 'release'):
    file = out / f'js00-{mode}.json'
    if file.exists():
        record = json.loads(file.read_text())
        for test in record['observations']:
            lines.append(f"| {mode} | {test['name']} | {test['status']} |")
lines += ['', '## Existing regressions', '',
          '| Gate | Result |', '| --- | --- |']
for name in ('core', 'step14', 'step15', 'step16'):
    status = out / f'existing-{name}.status'
    lines.append(f"| {name} | {status.read_text().strip() if status.exists() else 'NOT RUN'} |")
lines += ['', 'See js00-*.json for evidence and server-*.log for debug traces.',
          'Debug traces intentionally contain pre-fix secret cookie values:',
          'treat this output directory as sensitive and do not commit its contents.', '']
(out / 'REPORT.md').write_text('\n'.join(lines), encoding='utf-8')
print(f'Baseline report: {out / "REPORT.md"}')
PYREPORT
exit "$FAILED"
