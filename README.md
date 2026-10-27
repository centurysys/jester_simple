# Jester Simple

A lightweight, security-hardened **HTTP framework for Nim on Linux**, derived from
[Jester](https://github.com/dom96/jester) and Jesterfork. Jester Simple retains
familiar Jester-style routing for embedded management Web UIs while concentrating
on a single asynchronous HTTP transport and bounded resource usage.

This repository is maintained as **[centurysys/jester_simple](https://github.com/centurysys/jester_simple)**.
The Git repository name (`jester_simple`) and the Nim package/module name
(`jestersimple`) are intentionally different.

## Requirements and scope

- Linux on x86_64/amd64, arm64, or armhf where the toolchain supports the target.
- Nim **2.2.12 or newer** and the **ORC** memory manager (`--mm:orc`).
  The regression suite was developed against Nim 2.2.12; later versions and
  other CPU architectures require their own verification.
- An appropriate C compiler. Python 3 and Bash are needed only for the tests
  and performance tools, not for the application at runtime.
- `asyncdispatch`-based asynchronous HTTP handling. HTTPBeast and the previous
  platform-specific backends are not included.

The source currently declares version `1.0.0` in `jestersimple.nimble` and
`jestersimple.nim`. This is a source/package version, **not a claim that a
GitHub release tag or production certification has been completed**.

## Get started

```sh
git clone https://github.com/centurysys/jester_simple.git
cd jester_simple
nimble develop -y
```

Create `app.nim`:

```nim
import jestersimple

settings:
  bindAddr = "127.0.0.1"
  port = Port(5000)

routes:
  get "/":
    resp "Hello world"
```

Build and run from a Linux environment:

```sh
nim c --mm:orc -d:release --opt:size app.nim
./app
```

Open `http://127.0.0.1:5000/`. With a checkout-only setup, the alternative
is to pass the source directory explicitly with Nim's `--path:` option.

**Important:** without an explicit `bindAddr`, the default is a wildcard
network bind. Configure the listen address, authentication, reverse proxy and
firewall before making a service accessible from another host. The default
static directory is `./public` relative to the working directory; create and
populate it only if static file hosting is needed.

## HTTP behavior and security boundaries

- Request framing rejects ambiguous Content-Length / Transfer-Encoding
  combinations and malformed chunked input. Body, header, connection and
  receive-time limits are configurable.
- Query and form data are decoded exactly once. Malformed encodings and
  multipart bodies are rejected rather than silently normalized.
- `request.ip` uses the direct TCP peer unless explicitly configured trusted
  proxies supply the forwarding information. Reverse proxies must **replace**
  untrusted forwarding headers before relaying requests.
- Response header and cookie validation guards against CR/LF injection;
  unhandled exception pages do not disclose exception details.
- Static file access uses Linux directory-relative descriptors and does not
  follow symlinks under `staticDir`. Automatic static URL lookup returns 404
  for hidden filename components beginning with `.` (for example `.env`,
  `.git/config`, `sub/.config` and `.well-known/`). GET, HEAD and conditional
  ETag/304 responses are supported for public files. Weak ETags are derived
  from file metadata.
- Static files are transferred in bounded 16 KiB blocks. The response header
  and initial body block are combined to avoid unnecessary TCP delays for
  small files. Asynchronous raw streams should await `request.sendAsync()`.

The framework **does not** provide TLS termination, login/authentication,
application authorization, session management or CSRF protection. Those
remain the application's and deployment's responsibility.

### Static content and explicit file responses

`staticDir` is a **public document root**, not a safe place to store secrets.
Automatic GET/HEAD static lookup refuses hidden filename components starting
with a period, including percent-encoded leading periods, and responds with
404 even if the entry exists. The special traversal segments `.` and `..`
remain invalid paths (HTTP 400). Hidden directories are blocked at every depth. Ordinary
files with backup-like extensions (`.bak`, `.old`, etc.) are **not** blocked;
filename-extension blacklists are not a reliable security boundary. Store
configuration files, credentials, backups and private data outside `staticDir`.

This default also excludes `/.well-known/`. Serve ACME HTTP-01 challenges or
other deliberately public dot directories through a dedicated reverse-proxy
location or explicit application route, subject to application authorization.
There is no global "allow all dotfiles" switch.

`sendFile(filename)` has a **different trust contract**: the application
selects a filesystem pathname and may intentionally send files outside
`staticDir`, including dotfiles. `sendFile` is **not** confined by the static
URL policy; it does retain regular-file/permission checks, pinned-FD reads and
streaming. Never derive its pathname from untrusted URL/query parameters by
concatenation. If a route needs to serve client-selected files, use an explicit
allowlist or a separate confined file-selection mechanism. This step does not
introduce a new `sendFileUnder` API or alter existing explicit-file behavior.

Static Range/If-Range (`206`) and chunk extensions are not implemented.
Strict rejection of LF-only request line endings is not guaranteed. Do not
interpret successful regression tests as a complete security audit.

### Route pattern syntax errors

The optional-character marker `?` must immediately follow a literal character
(for example, `/report.?`). A leading `?` or a second `?` without an intervening
literal is invalid. A backslash escapes `?`, `@`, or `\`; an incomplete trailing
backslash or an escape before another character is invalid. Invalid patterns
raise `ValueError` rather than triggering an out-of-bounds defect, including
when parsed at compile time by a `router` macro.

## Configuration

Use the `settings:` macro or `newSettings()` to configure `maxBody`,
`maxConnections`, `maxHeaderBytes`, `maxHeaderFields`, `headerTimeoutMs`,
`bodyTimeoutMs`, `keepAliveTimeoutMs`, `managedSendTimeoutMs`,
`trustedProxies`, `allowedHosts` and
`publicBaseUrl`, in addition to the listen address, port and static directory.
A `trustedProxies` entry must identify the actual reverse-proxy peer or a
narrow CIDR. IPv4 and IPv6 `/0` networks (including `/00`) are rejected at
startup, because they would trust forwarding headers from arbitrary peers.
An empty list trusts no forwarded headers; `/32` (IPv4) and `/128` (IPv6)
select a single peer. Reverse proxies must discard or replace untrusted
`Forwarded` and `X-Forwarded-*` headers before relaying requests.

`allowedHosts` restricts which Host/forwarded host values may become
`request.host` and appear in generated absolute URLs (`makeUri`). An empty
list retains the local-development fallback: `localhost`, `127.0.0.1`,
`[::1]`, and a non-wildcard bind address are eligible. A nonempty list is
**exhaustive**: these local/bind hosts are not accepted implicitly and must
be listed explicitly if needed. Matching is case-insensitive and compares
hosts without their optional request port; the configured entries must not
include ports. Unknown hosts produce an empty `request.host`, and `makeUri`
falls back to a relative URL. This setting does **not** reject HTTP requests
with an unlisted Host header; use an upstream virtual-host/access policy if
request rejection is required. `publicBaseUrl`, when explicitly configured,
still supplies the canonical application origin regardless of request Host or
`allowedHosts` and should be treated as an independently trusted setting.
The `managedSendTimeoutMs` default is 15000 ms (15 seconds) and bounds each
transport-managed HTTP socket send; it does not time out an upgraded
WebSocket session or a long-running route handler. See
[HTTP Upgrade contract](docs/upgrade_contract.md) for exact scope.
Choose values based on the target device's memory and CPU budget.

## Tests and performance measurements

Run from the repository root:

```sh
nimble test -y
python3 tests/integration/test_step16_probe.py
python3 tests/perf/test_step17_tools.py
python3 tests/integration/run_step16_suite.py
bash tests/perf/run_step17.sh docs/performance/step17-amd64
```

The full suite runs the historical HTTP regressions in separate subprocesses,
collects failures and stores generated reports under ignored `docs/` paths.
There is no GitHub Actions workflow; tests are run locally.

The performance harness uses a **sequential Python HTTP client on loopback**;
its RPS and latency values are not a peak-throughput benchmark. For embedded
Linux deployment, verify memory/FD/CPU usage on the actual board (especially
Cortex-A5/armhf) and exercise a representative management UI.

## Documentation

- [Changelog](CHANGELOG.md)
- [Migration from Jesterfork](docs/migration/jesterfork_to_jestersimple.md)
- [Repeatable performance measurements](docs/performance/step17.md)
- [Initial-release checklist](docs/release/RELEASE_CHECKLIST.md)
- [Technical summary of changes](docs/release/CHANGES_FOR_INITIAL_RELEASE.md)

## License and provenance

MIT license. Derived from the work of Dominik Picheta and Jesterfork
contributors. The original `license.txt` and source-level copyright notices
are retained. The prior Jester release history is documented upstream at
[dom96/jester](https://github.com/dom96/jester).

### JS-06 HTTP output budgets

`newSettings` exposes `responseStartTimeoutMs` (default 15s) and
`streamTotalTimeoutMs` (default 60s), in addition to the JS-05
`managedSendTimeoutMs` (default 15s). Managed static-file responses are
streamed in 16KiB chunks with bounded per-chunk and whole-stream deadlines.
HTTP Upgrade is excluded from the response-start deadline once begun.

These limits govern network output and the response-start phase; they cannot
preempt an indefinitely running application Future or guarantee RSS returns
to the OS. See `docs/upgrade_contract.md` and `tests/http/run_js06.sh`.
