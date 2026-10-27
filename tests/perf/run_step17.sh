#!/usr/bin/env bash
# Step 17: local release-build performance and footprint snapshot.
# Usage: bash tests/perf/run_step17.sh [output-dir] [legacy-jesterfork-source-dir]
# Does not change the repository, does not exit its invoking interactive shell.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "$ROOT"
OUT="${1:-docs/performance/step17-results}"
LEGACY="${2:-}"
if [[ "$OUT" != /* ]]; then OUT="$ROOT/$OUT"; fi
mkdir -p -- "$OUT"
OUT=$(cd -- "$OUT" && pwd -P)
for cmd in nim python3 git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$cmd" >&2
    exit 2
  fi
done
if [[ -n "$LEGACY" ]]; then
  LEGACY=$(cd -- "$LEGACY" && pwd -P)
  if [[ ! -f "$LEGACY/jesterfork.nim" ]]; then
    echo "Not a jesterfork source directory: $LEGACY" >&2
    exit 2
  fi
fi
# Avoid accidentally hitting an unrelated daemon on the fixed test port.
python3 - <<'PYCHECK'
import socket
with socket.socket() as s:
    try:
        s.bind(('127.0.0.1', 5517))
    except OSError as exc:
        raise SystemExit(f'Step 17: port 5517 unavailable: {exc}')
PYCHECK
TMP=$(mktemp -d)
PID=""
stop_server() {
  if [[ -n "$PID" ]]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
  fi
}
cleanup() {
  stop_server
  rm -rf -- "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$TMP/public"
printf 'step17 small static fixture\n' > "$TMP/public/small.txt"
# Deterministic content; no package requirements and no random-data timings.
python3 - "$TMP/public" "$TMP/fixtures.json" <<'PYFIX'
import hashlib, json, sys
from pathlib import Path
root, metadata = Path(sys.argv[1]), Path(sys.argv[2])
data = {}
for label, name, size in [('large', 'large.bin', 2*1024*1024),
                          ('huge', 'huge.bin', 32*1024*1024)]:
    path = root / name
    hasher = hashlib.sha256()
    part = b'\0' * 65536
    with path.open('wb') as f:
        for _ in range(size // len(part)):
            f.write(part)
            hasher.update(part)
    data[label] = {'size': size, 'sha256': hasher.hexdigest()}
metadata.write_text(json.dumps(data, indent=2) + '\n')
PYFIX
{
  echo "Captured UTC: $(date -u +%FT%TZ)"
  echo "Host: $(uname -srm)"
  echo "CPU:"; grep -m1 -E 'model name|Hardware|Processor' /proc/cpuinfo || true
  echo "Nim:"; nim --version | head -n2
  echo "C compiler:"; (cc --version | head -n1) 2>/dev/null || true
  echo "Git HEAD: $(git rev-parse HEAD)"
  echo "Git status:"; git status --short || true
  echo "Flags: --mm:orc -d:release --opt:size (both builds)"
  echo "Extra compiler flags: ${STEP17_NIM_EXTRA_FLAGS:-none}"
  echo "Client: Python http.client, single connection, serial requests"
  echo "Port: 127.0.0.1:5517"
} > "$OUT/environment.txt"

run_variant() {
  local label="$1" binary="$2" git_head="$3" source_dir="$4"
  local variant_out="$OUT/$label"
  mkdir -p "$variant_out"
  local -a opts=(--mm:orc -d:release --opt:size --hints:off)
  # The same user-selected flags are applied to both variants.
  if [[ -n "${STEP17_NIM_EXTRA_FLAGS:-}" ]]; then
    local -a extras=()
    read -r -a extras <<< "$STEP17_NIM_EXTRA_FLAGS"
    opts+=("${extras[@]}")
  fi
  if [[ "$label" == legacy ]]; then
    opts+=(-d:step17Legacy -d:useStdLib "--path:$source_dir")
  else
    opts+=(--path:.)
  fi
  printf 'Building %s\n' "$label"
  if ! nim c "${opts[@]}" "--out:$binary" tests/perf/step17_app.nim \
    > "$variant_out/build.log" 2>&1; then
    tail -n 70 "$variant_out/build.log" >&2
    echo "Build failed for $label" >&2
    return 1
  fi
  if command -v size >/dev/null 2>&1; then
    size "$binary" > "$variant_out/binary-sections.txt" 2>&1 || true
  fi
  if command -v ldd >/dev/null 2>&1; then
    ldd "$binary" > "$variant_out/dynamic-libraries.txt" 2>&1 || true
  fi
  JESTER_STEP17_STATIC_DIR="$TMP/public" "$binary" > "$variant_out/server.log" 2>&1 &
  PID=$!
  local startup_begin=$SECONDS
  if ! python3 - "$PID" <<'PYREADY'
import http.client, os, sys, time
pid = int(sys.argv[1])
for _ in range(100):
    try:
        connection = http.client.HTTPConnection('127.0.0.1', 5517, timeout=.5)
        connection.request('GET', '/bench/plain')
        response = connection.getresponse()
        okay = response.status == 200 and response.read() == b'OK'
        connection.close()
        if okay: raise SystemExit(0)
    except (OSError, TimeoutError, http.client.HTTPException):
        pass
    time.sleep(.1)
raise SystemExit('Server did not become ready')
PYREADY
  then
    tail -n 80 "$variant_out/server.log" >&2
    stop_server
    return 1
  fi
  echo "Ready in approximately $((SECONDS-startup_begin)) s" > "$variant_out/startup.txt"
  local -a opts_probe=(--pid "$PID" --out "$variant_out" --label "$label" \
    --git-head "$git_head" --binary "$binary" --fixtures "$TMP/fixtures.json")
  if [[ "${STEP17_QUICK:-0}" == 1 ]]; then
    opts_probe+=(--count 40 --repeats 1 --large-count 2 --huge-count 1 --footprint-count 50)
  fi
  local status=0
  python3 tests/perf/step17_probe.py "${opts_probe[@]}" || status=$?
  stop_server
  return "$status"
}

HEAD=$(git rev-parse HEAD)
# Compile into a temporary directory and preserve metadata, not binaries.
if [[ -n "$LEGACY" ]]; then
  LEGACY_HEAD=$(git -C "$LEGACY" rev-parse HEAD 2>/dev/null || echo unknown)
  run_variant legacy "$TMP/step17-legacy" "$LEGACY_HEAD" "$LEGACY"
fi
run_variant current "$TMP/step17-current" "$HEAD" "$ROOT"
if [[ -n "$LEGACY" ]]; then
  python3 tests/perf/compare_step17.py "$OUT/legacy/RESULTS.json" \
    "$OUT/current/RESULTS.json" --out "$OUT/COMPARISON.md"
else
  echo 'Legacy comparison: NOT MEASURED (provide a second argument with old source).' \
    > "$OUT/COMPARISON_NOT_MEASURED.txt"
fi
printf '\nStep 17 measurements: %s\n' "$OUT"
