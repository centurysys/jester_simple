#!/usr/bin/env bash
# Step 0/1/2: compare the single standard HTTP backend on Linux.
# Usage: bash tests/baseline/run_step0.sh [output-directory]
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "$repo"

# The baseline harness is also used after the package-only rename.
if [[ -f jestersimple.nim ]]; then
  framework_module=jestersimple
elif [[ -f jesterfork.nim ]]; then
  framework_module=jesterfork
else
  echo 'Neither jestersimple.nim nor jesterfork.nim found.' >&2
  exit 2
fi

out=${1:-docs/baseline/step0-results}
if [[ "$out" != /* ]]; then
  out="$repo/$out"
fi
mkdir -p "$out"
out=$(cd -- "$out" && pwd -P)

# Restrict all network probes to a locally owned server on loopback.
url='http://127.0.0.1:5480'
app='tests/baseline/baseline_app.nim'
tmp=$(mktemp -d)
server_pid=''
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/bin" "$tmp/public" "$out/compiles" "$out/benchmarks"
printf 'baseline small static fixture\n' > "$tmp/public/small.txt"
dd if=/dev/zero of="$tmp/public/large.bin" bs=1048576 count=2 status=none

{
  printf 'Captured UTC: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
  printf 'Repository: %s\n' "$repo"
  printf 'Branch: '; git branch --show-current 2>/dev/null || true
  printf 'HEAD: '; git rev-parse HEAD 2>/dev/null || true
  printf 'OS: '; uname -srm
  printf 'Architecture: '; uname -m
  printf 'Nim: '; if command -v nim >/dev/null 2>&1; then nim --version | head -n 2; else echo 'NOT INSTALLED'; fi
  printf 'Nimble: '; if command -v nimble >/dev/null 2>&1; then nimble --version; else echo 'NOT INSTALLED'; fi
  printf 'C compiler: '; if command -v cc >/dev/null 2>&1; then cc --version | head -n 1; else echo 'NOT FOUND'; fi
  printf 'wrk: '; if command -v wrk >/dev/null 2>&1; then command -v wrk; else echo 'NOT INSTALLED'; fi
  printf 'curl: '; if command -v curl >/dev/null 2>&1; then command -v curl; else echo 'NOT INSTALLED'; fi
  printf 'CPU info:\n'; grep -m 1 -E 'model name|Hardware|Processor' /proc/cpuinfo || true
  printf 'MemTotal: '; grep '^MemTotal:' /proc/meminfo || true
  printf 'Kernel: '; uname -v
  printf 'Nim compiler flags: --mm:orc (and -d:release for release)\n'
} > "$out/environment.txt"

git status --porcelain=v1 > "$out/worktree_status.txt" 2>&1 || true
{
  find "$framework_module" -type f -name '*.nim' -print
  printf '%s.nim\n%s.nimble\n' "$framework_module" "$framework_module"
} | sort | xargs -r sha256sum > "$out/source_sha256.txt"

# API snapshot is intentionally a textual inventory, not a Nim symbol parser.
grep -R -nE '^([[:space:]]*(proc|func|template|macro|iterator|converter)[[:space:]]+[^=]*\*|[[:space:]]+[A-Za-z_][A-Za-z0-9_]*\*([[:space:]:({,]|$)|export[[:space:]])' \
  "$framework_module.nim" "$framework_module/" > "$out/public_api_candidates.txt" || true
grep -R -nE '\bbindSym\b|\bexport\b' "$framework_module.nim" "$framework_module/" \
  > "$out/macro_bindings_and_exports.txt" || true

printf 'target\tmode\tstatus\n' > "$out/compile_results.tsv"
failed=0
if ! command -v nim >/dev/null 2>&1; then
  echo 'Nim not found; cannot perform Step 0 builds.' | tee "$out/build_error.txt" >&2
  exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo 'curl not found; cannot perform Step 0 HTTP probes.' | tee "$out/build_error.txt" >&2
  exit 2
fi

compile() {
  local file=$1 mode=$2 name=$3
  local log="$out/compiles/${name}_${mode}.log"
  local -a opts=(--mm:orc --hints:off --path:. )
  if [[ "$mode" == release ]]; then
    opts+=(-d:release)
  fi
  echo "Building $file ($mode)"
  if nim c "${opts[@]}" --out:"$tmp/bin/${name}_${mode}" "$file" > "$log" 2>&1; then
    printf '%s\t%s\tOK\n' "$file" "$mode" >> "$out/compile_results.tsv"
  else
    printf '%s\t%s\tFAIL\n' "$file" "$mode" >> "$out/compile_results.tsv"
    failed=1
  fi
}

compile "$app" debug baseline
compile "$app" release baseline
for name in alltest issue150 customRouter issue247 benchmark fileupload example example2; do
  compile "tests/${name}.nim" release "$name"
done

if [[ ! -x "$tmp/bin/baseline_release" ]]; then
  echo 'Baseline server failed to compile; see compiles/baseline_release.log' > "$out/smoke_results.txt"
  exit 1
fi

# All measurements use the baseline app; no changes to the original sources.
# The fixed port must be free. Do not accidentally benchmark another process.
if curl --silent --fail --max-time 1 "$url/baseline/plain" >/dev/null 2>&1; then
  echo 'Port 5480 is already serving the baseline URL. Stop it first.' >&2
  exit 3
fi
JESTER_BASELINE_STATIC_DIR="$tmp/public" "$tmp/bin/baseline_release" \
  > "$out/server.log" 2>&1 &
server_pid=$!
ready=0
for ((attempt=0; attempt<50; attempt++)); do
  if ! kill -0 "$server_pid" 2>/dev/null; then break; fi
  if [[ $(curl -sS --max-time 1 "$url/baseline/plain" 2>/dev/null || true) == OK ]]; then
    ready=1
    break
  fi
  sleep 0.1
done
if (( ready == 0 )); then
  echo 'Baseline app did not start; see server.log' >&2
  exit 4
fi

rss_fd() {
  local label=$1
  {
    echo "[$label]"
    grep -E '^Vm(RSS|HWM|Size):' "/proc/$server_pid/status" || true
    printf 'fd_count: '
    find "/proc/$server_pid/fd" -mindepth 1 -maxdepth 1 -type l 2>/dev/null | wc -l
  } >> "$out/process_memory.txt"
}
rss_fd startup

printf 'probe\tstatus\tcheck\n' > "$out/smoke_results.tsv"
smoke() {
  local name=$1 method=$2 path=$3 expected=$4; shift 4
  local code body
  code=$(curl --silent --show-error --max-time 8 --request "$method" \
    --output "$tmp/response.txt" --write-out '%{http_code}' "$@" "$url$path") || {
      printf '%s\tTRANSPORT_ERROR\tFAIL\n' "$name" >> "$out/smoke_results.tsv"
      failed=1
      return
    }
  body=$(cat "$tmp/response.txt")
  if [[ "$code" == 200 && "$body" == "$expected" ]]; then
    printf '%s\t%s\tOK\n' "$name" "$code" >> "$out/smoke_results.tsv"
  else
    printf '%s\t%s\tFAIL\n' "$name" "$code" >> "$out/smoke_results.tsv"
    failed=1
  fi
}
smoke plain GET /baseline/plain 'OK'
smoke json GET /baseline/json '{"status":"ok","count":42}'
smoke query GET '/baseline/query?q=test&field=5' 'q=test&field=5'
smoke params GET '/baseline/params?value=abc' 'abc'
smoke post POST '/baseline/echo' 'baseline-post' --data-binary 'baseline-post'
smoke static_small GET '/small.txt' 'baseline small static fixture'

# Check large-file integrity separately (the body contains zero bytes).
if curl --silent --show-error --fail --max-time 15 --output "$tmp/download.bin" \
  "$url/large.bin" && cmp -s "$tmp/public/large.bin" "$tmp/download.bin"; then
  printf 'static_large\t200\tOK\n' >> "$out/smoke_results.tsv"
else
  printf 'static_large\tunknown\tFAIL\n' >> "$out/smoke_results.tsv"
  failed=1
fi

# A reproducible minimum of 1,000 requests, independent of wrk availability.
# This is a process/RSS stress check, NOT a throughput benchmark (curl forks).
load_ok=0
for ((i=0; i<1000; i++)); do
  if curl --silent --fail --max-time 5 --output /dev/null "$url/baseline/plain"; then
    ((load_ok+=1))
  fi
done
printf 'Attempted: 1000\nSuccessful: %d\n' "$load_ok" > "$out/load_1000.txt"
if (( load_ok != 1000 )); then failed=1; fi
rss_fd after_1000_requests

if command -v wrk >/dev/null 2>&1; then
  cat > "$tmp/post.lua" <<'LUA'
wrk.method = "POST"
wrk.body = "baseline-post"
wrk.headers["Content-Type"] = "text/plain"
LUA
  printf 'route\trepeat\trps\tp50\tp99\n' > "$out/benchmarks/summary.tsv"
  for entry in 'plain:/baseline/plain' 'json:/baseline/json' \
               'query:/baseline/query?q=test&field=5' 'small:/small.txt' \
               'large:/large.bin' 'post:/baseline/echo'; do
    name=${entry%%:*}
    path=${entry#*:}
    for run in 1 2 3; do
      log="$out/benchmarks/${name}_${run}.txt"
      if [[ "$name" == post ]]; then
        wrk -t1 -c1 -d5s --latency -s "$tmp/post.lua" "$url$path" > "$log" 2>&1 || failed=1
      else
        wrk -t1 -c1 -d5s --latency "$url$path" > "$log" 2>&1 || failed=1
      fi
      rps=$(awk '/Requests\/sec:/ {print $2}' "$log" | tail -n 1)
      p50=$(awk '$1 == "50%" {print $2}' "$log" | tail -n 1)
      p99=$(awk '$1 == "99%" {print $2}' "$log" | tail -n 1)
      printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$run" "${rps:-NA}" "${p50:-NA}" "${p99:-NA}" \
        >> "$out/benchmarks/summary.tsv"
    done
  done
  rss_fd after_benchmarks
else
  echo 'wrk not installed; RPS/p50/p99: NOT MEASURED' > "$out/benchmarks/NOT_MEASURED.txt"
fi

{
  command -v size >/dev/null 2>&1 && size "$tmp/bin/baseline_release" || true
} > "$out/binary_size.txt" 2>&1
{
  command -v ldd >/dev/null 2>&1 && ldd "$tmp/bin/baseline_release" || true
} > "$out/dynamic_dependencies.txt" 2>&1
stat -c 'release_binary_bytes: %s' "$tmp/bin/baseline_release" \
  > "$out/binary_file_size.txt"

{
  echo "# ${framework_module} baseline measurement"
  echo
  echo 'This is a baseline of the existing source, NOT a security acceptance test.'
  echo
  echo '## Environment'
  echo '```text'
  cat "$out/environment.txt"
  echo '```'
  echo
  echo '## Compile results'
  echo '```text'
  cat "$out/compile_results.tsv"
  echo '```'
  echo
  echo '## HTTP smoke probes'
  echo '```text'
  cat "$out/smoke_results.tsv"
  echo '```'
  echo
  echo '## RSS / file descriptors'
  echo '```text'
  cat "$out/process_memory.txt"
  echo '```'
  echo
  echo '## 1,000-request load check'
  echo '```text'
  cat "$out/load_1000.txt"
  echo '```'
  echo
  echo '## Benchmark results'
  if [[ -f "$out/benchmarks/summary.tsv" ]]; then
    echo '```text'; cat "$out/benchmarks/summary.tsv"; echo '```'
  else
    echo 'Not measured (wrk unavailable).'
  fi
  echo
  echo '## Notes'
  echo '- Baseline build: Nim 2.2.12 intended; check actual version above.'
  echo '- Backend: standard asynchttpserver (single backend; no selector needed).'
  echo '- All probes restricted to 127.0.0.1:5480.'
  echo '- 1,000 curl requests are for memory/fd observation, not RPS.'
  echo '- wrk uses one connection, one thread, five seconds, three repeats per route.'
  echo '- Unmodified legacy tester is not run because it executes both backends and uses asynctools.'
  echo '- The source API inventory is an approximate textual listing, not compiler-validated.'
  echo '- All untouched source checksums are in source_sha256.txt.'
} > "$out/RESULTS.md"

printf 'Step 0 results: %s/RESULTS.md\n' "$out"
if (( failed != 0 )); then
  echo 'Some builds or probes failed. Keep the failure logs; do not mark Step 0 green.' >&2
  exit 1
fi
