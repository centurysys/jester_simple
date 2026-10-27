#!/usr/bin/env bash
# JS-10: route parser bounds and compile-time router diagnostics.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-/tmp/jestersimple_js10}"
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

  echo "=== JS-10 $mode: parser unit tests ==="
  if ! nim c -r "${flags[@]}" --out:"$OUT/js10_unit_$mode" \
    tests/http/js10_unit.nim > "$OUT/unit-$mode.log" 2>&1; then
    tail -n 120 "$OUT/unit-$mode.log" >&2
    exit 1
  fi
  echo PASS > "$OUT/unit-$mode.status"

  echo "=== JS-10 $mode: valid router ==="
  if ! nim c "${flags[@]}" --out:"$OUT/js10_router_$mode" \
    tests/http/js10_router.nim > "$OUT/router-$mode.log" 2>&1; then
    tail -n 120 "$OUT/router-$mode.log" >&2
    exit 1
  fi
  echo PASS > "$OUT/router-$mode.status"

  # A malformed compile-time router must fail with the parser's own
  # ValueError message, not an internal out-of-bounds defect or unrelated error.
  while IFS='|' read -r case_name define_name expected; do
    echo "=== JS-10 $mode: expected rejection $case_name ==="
    log="$OUT/reject-$case_name-$mode.log"
    if nim c "${flags[@]}" "-d:$define_name" \
      --out:"$OUT/js10_invalid_${case_name}_$mode" \
      tests/http/js10_router.nim > "$log" 2>&1; then
      echo "ERROR: invalid router unexpectedly compiled: $case_name ($mode)" >&2
      exit 1
    fi
    if ! grep -Fq -- "$expected" "$log"; then
      echo "ERROR: expected ValueError description not found: $case_name ($mode)" >&2
      tail -n 120 "$log" >&2
      exit 1
    fi
    if grep -Eq 'IndexDefect|RangeDefect' "$log"; then
      echo "ERROR: internal index/range defect surfaced: $case_name ($mode)" >&2
      tail -n 120 "$log" >&2
      exit 1
    fi
    echo PASS > "$OUT/reject-$case_name-$mode.status"
  done <<'CASES'
leading-optional|js10InvalidLeadingOptional|Optional marker '?' must follow a literal character
trailing-escape|js10InvalidTrailingEscape|Trailing escape character in route pattern
CASES
done

if [[ "${JS10_SKIP_EXISTING:-0}" != 1 ]]; then
  command -v nimble >/dev/null || { echo 'Missing: nimble' >&2; exit 2; }
  while IFS='|' read -r name command; do
    echo "=== Existing regression gate: $name ==="
    if bash -c "$command" > "$OUT/existing-$name.log" 2>&1; then
      echo PASS > "$OUT/existing-$name.status"
    else
      echo FAIL > "$OUT/existing-$name.status"
      tail -n 120 "$OUT/existing-$name.log" >&2
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
step16|bash tests/integration/run_step16.sh '$OUT/existing-step16'
GATES
fi

python3 - "$OUT" <<'PYREPORT'
import sys
from pathlib import Path
out = Path(sys.argv[1])
lines = [
    '# JS-10 route pattern bounds regression', '',
    'Malformed patterns must produce ValueError instead of an indexing defect.',
    '', '| Build | Parser unit | Valid router | Leading ? rejected | Trailing \\ rejected |',
    '| --- | --- | --- | --- | --- |',
]
for mode in ('debug', 'release'):
    def status(name):
        path = out / name
        return path.read_text().strip() if path.exists() else 'NOT RUN'
    lines.append(
        f'| {mode} | {status(f"unit-{mode}.status")} | '
        f'{status(f"router-{mode}.status")} | '
        f'{status(f"reject-leading-optional-{mode}.status")} | '
        f'{status(f"reject-trailing-escape-{mode}.status")} |'
    )
lines += ['', '## Existing regression gates', '', '| Gate | Result |', '| --- | --- |']
for name in ('core', 'step9', 'step13', 'step14', 'step15',
             'js01', 'js01b', 'js02', 'js03', 'js04', 'js05',
             'js06', 'js07', 'js08', 'js09', 'step16'):
    path = out / f'existing-{name}.status'
    lines.append(f'| {name} | {path.read_text().strip() if path.exists() else "NOT RUN"} |')
lines += ['', 'Nim 2.2.12 / ORC, Debug and Release.',
          'Test executables and compiler logs belong in the output directory, not Git.', '']
report = '\n'.join(lines)
(out / 'REPORT.md').write_text(report, encoding='utf-8')
print(report)
PYREPORT
