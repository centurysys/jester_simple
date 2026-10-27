#!/usr/bin/env bash
# JS-07: trustedProxies /0 validation and forwarding-header trust boundary.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-/tmp/jestersimple_js07}"
mkdir -p -- "$OUT"
OUT="$(realpath "$OUT")"

for tool in nim python3 git; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 2; }
done
nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git branch --show-current > "$OUT/git-branch.txt"
git status --short > "$OUT/git-status.txt"

for mode in debug release; do
  flags=(--mm:orc --hints:off --path:.)
  if [[ "$mode" == release ]]; then flags+=(-d:release); fi

  if ! nim c -r "${flags[@]}" --out:"$OUT/js07_unit_$mode" \
      tests/http/js07_unit.nim > "$OUT/unit-$mode.log" 2>&1; then
    tail -n 100 "$OUT/unit-$mode.log" >&2
    exit 1
  fi

  if ! nim c "${flags[@]}" --out:"$OUT/js07_startup_$mode" \
      tests/http/js07_startup.nim > "$OUT/build-$mode.log" 2>&1; then
    tail -n 100 "$OUT/build-$mode.log" >&2
    exit 1
  fi

  if ! python3 - "$OUT/js07_startup_$mode" "$OUT" "$mode" <<'PYSTARTUP'
import json
import subprocess
import sys
from pathlib import Path

binary = sys.argv[1]
out = Path(sys.argv[2])
mode = sys.argv[3]
results = []
for kind in ("ipv4", "ipv6", "ipv4-padded", "ipv6-padded"):
    try:
        run = subprocess.run([binary, kind], capture_output=True,
                             text=True, timeout=3)
    except subprocess.TimeoutExpired:
        raise SystemExit(f"FAIL {mode}: {kind}: serve() did not reject /0")
    expected = f"JS07_STARTUP_REJECTED:{kind}"
    passed = run.returncode == 0 and expected in run.stdout.splitlines()
    results.append({"case": kind, "result": "PASS" if passed else "FAIL"})
    if not passed:
        print(f"FAIL {mode}: {kind}: rc={run.returncode} "
              f"stdout={run.stdout!r} stderr={run.stderr!r}", file=sys.stderr)
    else:
        print(f"PASS {mode}: startup rejects {kind}")
(out / f"js07-{mode}.json").write_text(
    json.dumps({"mode": mode, "startup": results}, indent=2) + "\n",
    encoding="utf-8")
if not all(case["result"] == "PASS" for case in results):
    raise SystemExit(1)
PYSTARTUP
  then
    exit 1
  fi
done

if [[ "${JS07_SKIP_EXISTING:-0}" != 1 ]]; then
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
    '# JS-07 trusted proxy /0 regression', '',
    'CIDR policy: /0 is valid matching syntax but forbidden in trustedProxies.',
    '', '| Build | Unit | Startup rejections |',
    '| --- | --- | ---: |',
]
for mode in ('debug', 'release'):
    report = json.loads((out / f'js07-{mode}.json').read_text())
    unit_log = (out / f'unit-{mode}.log').read_text()
    passed = sum(1 for case in report['startup'] if case['result'] == 'PASS')
    # Nim unittest exits nonzero on failed checks; the runner aborts at that point.
    lines.append(f'| {mode} | PASS | {passed}/{len(report["startup"])} |')
lines += ['', '## Existing regression gates', '',
          '| Gate | Status |', '| --- | --- |']
for name in ('core', 'step9', 'js01', 'js01b', 'js02', 'js03',
             'js04', 'js05', 'js06', 'step14', 'step15', 'step16'):
    path = out / f'existing-{name}.status'
    lines.append(f'| {name} | {path.read_text().strip() if path.exists() else "NOT RUN"} |')
lines += ['', 'All tests run with Nim ORC in Debug and Release modes.',
          'Generated binaries and logs remain outside the repository.', '']
(out / 'REPORT.md').write_text('\n'.join(lines), encoding='utf-8')
print('\n'.join(lines))
PYREPORT
