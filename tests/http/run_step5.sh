#!/usr/bin/env bash
# Step 5: loopback-only HTTP framing regression with hard failure on defects.
set -euo pipefail

cd "$(dirname "$0")/../.."
OUT="${1:-docs/modernization/step5-results}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
APP="$OUT/step5_server"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

command -v nim >/dev/null || { echo 'nim is required' >&2; exit 2; }
command -v python3 >/dev/null || { echo 'python3 is required' >&2; exit 2; }
command -v ss >/dev/null || { echo 'ss is required' >&2; exit 2; }
if ss -H -ltn 'sport = :5481' | grep -q .; then
  echo 'Port 5481 is already in use; refusing to run.' >&2
  exit 2
fi

nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git status --short > "$OUT/git-status.txt"

# Run against the existing Step 4 fixture to ensure Jester integration.
nim c --mm:orc -d:release --hints:off --path:. \
  --out:"$APP" tests/http/step4_server.nim > "$OUT/build.log" 2>&1 || {
  cat "$OUT/build.log" >&2
  exit 1
}
"$APP" > "$OUT/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 40); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$OUT/server.log" >&2
    exit 1
  fi
  if ss -H -ltn 'sport = :5481' | grep -q '127.0.0.1:5481'; then
    break
  fi
  sleep 0.1
done
if ! ss -H -ltn 'sport = :5481' | grep -q '127.0.0.1:5481'; then
  echo 'Step 5 server did not listen on loopback.' >&2
  exit 1
fi

python3 tests/http/step5_probe.py "$OUT"
