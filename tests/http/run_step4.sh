#!/usr/bin/env bash
# Step 4: isolated loopback-only transport characterization (Linux)
set -euo pipefail

cd "$(dirname "$0")/../.."
OUT="${1:-docs/modernization/step4-results}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
APP="$OUT/step4_server"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

command -v nim >/dev/null || { echo 'nim is required' >&2; exit 2; }
command -v python3 >/dev/null || { echo 'python3 is required for raw TCP probes' >&2; exit 2; }
command -v ss >/dev/null || { echo 'ss (iproute2) is required for port safety check' >&2; exit 2; }

if ss -H -ltn 'sport = :5481' | grep -q .; then
  echo 'Refusing to start: TCP 5481 is already in use.' >&2
  exit 2
fi

nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git status --short > "$OUT/git-status.txt"
uname -a > "$OUT/uname.txt"
printf '%s\n' 'Compiler flags: --mm:orc -d:release --path:.' > "$OUT/build-flags.txt"

nim c --mm:orc --hints:off --path:. \
  --out:"${APP}_debug" tests/http/step4_server.nim > "$OUT/build-debug.log" 2>&1 || {
  cat "$OUT/build-debug.log" >&2
  exit 1
}
nim c --mm:orc -d:release --hints:off --path:. \
  --out:"$APP" tests/http/step4_server.nim > "$OUT/build.log" 2>&1 || {
  cat "$OUT/build.log" >&2
  exit 1
}
"$APP" > "$OUT/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 30); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo 'Step 4 server terminated before listening.' >&2
    cat "$OUT/server.log" >&2
    exit 1
  fi
  if ss -H -ltn 'sport = :5481' | grep -q '127.0.0.1:5481'; then
    break
  fi
  sleep 0.1
done
if ! ss -H -ltn 'sport = :5481' | grep -q '127.0.0.1:5481'; then
  echo 'Step 4 server did not listen on 127.0.0.1:5481.' >&2
  exit 1
fi

python3 tests/http/step4_probe.py --pid "$SERVER_PID" --output "$OUT"
echo "Outputs written to $OUT"
