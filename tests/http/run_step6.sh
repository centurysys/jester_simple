#!/usr/bin/env bash
# Step 6: localhost-only resource and deadline regression.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-docs/modernization/step6-results}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
APP="$OUT/step6_server"
SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM
for cmd in nim python3 ss; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 2; }
done
if ss -H -ltn 'sport = :5482' | grep -q .; then
  echo 'Port 5482 is in use.' >&2
  exit 2
fi
nim --version > "$OUT/nim-version.txt"
git rev-parse HEAD > "$OUT/git-head.txt"
git status --short > "$OUT/git-status.txt"
nim c --mm:orc -d:release --hints:off --path:. \
  --out:"$APP" tests/http/step6_server.nim > "$OUT/build.log" 2>&1 || {
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
  if ss -H -ltn 'sport = :5482' | grep -q '127.0.0.1:5482'; then
    break
  fi
  sleep 0.1
done
if ! ss -H -ltn 'sport = :5482' | grep -q '127.0.0.1:5482'; then
  echo 'Server did not bind 127.0.0.1:5482.' >&2
  exit 1
fi
python3 tests/http/step6_probe.py "$OUT" "$SERVER_PID"
