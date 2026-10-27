# Jester Simple

Jester Simple is a compact **Linux-only** Nim HTTP routing framework derived
from Jester/Jesterfork. It targets embedded management Web UIs and applications
that benefit from asynchronous I/O without a separate threaded HTTP backend.

## Requirements

- Linux (amd64, arm64, armhf where supported by the Nim toolchain).
- Nim **2.2.12 or newer**, built with `--mm:orc`.
- `asyncdispatch` and the internal HTTP transport. HTTPBeast is **not** used.
- A C toolchain appropriate for the target Linux platform.

The bundled regression suite is built with Nim 2.2.12. Other Nim versions and
embedded targets require independent verification before deployment.

## Minimal application

```nim
import jestersimple

routes:
  get "/":
    resp "Hello world"
```

Build with `nim c --mm:orc -d:release --opt:size app.nim`.
By default the server listens on port 5000. Restrict network exposure and
set `bindAddr`, authentication and TLS termination in your deployment plan.

The `settings` macro can configure `maxBody`, `maxConnections`,
`maxHeaderBytes`, `maxHeaderFields`, `headerTimeoutMs`, `bodyTimeoutMs`,
`keepAliveTimeoutMs`, `trustedProxies`, `allowedHosts`, and `publicBaseUrl`.
The defaults are conservative starting points; they are not sufficient for
every network threat model or workload.

## HTTP and trust boundaries

- Body size limits are enforced for Content-Length and chunked inputs.
- Ambiguous HTTP framing, malformed multipart, invalid Host and output headers
  are rejected.
- `request.ip` uses the TCP peer by default. Forwarding metadata is considered
  only for trusted proxy peers. Proxies must overwrite untrusted headers.
- Static files are served from verified Linux file descriptors. Symlinks under
  the public directory are not followed.
- Large responses use bounded streaming. Raw streaming users should await
  `request.sendAsync()` to manage backpressure.
- The framework does **not** supply TLS, login/authentication, session
  management, CSRF protection or application-specific authorization.

When reachable by untrusted networks, use a properly configured reverse proxy,
TLS, ACLs, suitable monitoring, and application authentication. Review the
known protocol limitations in the release checklist before production use.

## Testing and performance

```sh
nimble test -y
python3 tests/integration/run_step16_suite.py
python3 tests/perf/test_step17_tools.py
bash tests/perf/run_step17.sh
```

The Step 17 measurements use loopback and a Python serial HTTP client. They do
not prove peak RPS or release readiness. For Cortex-A5 deployments, measure
on an actual armhf board and record its CPU, RAM, startup footprint and
application-level throughput.

## Documentation

- [Jesterfork migration and API compatibility](docs/migration/jesterfork_to_jestersimple.md)
- [Step 17 repeatable performance measurements](docs/performance/step17.md)
- [Initial release checklist](docs/release/RELEASE_CHECKLIST.md)
- [Proposed changes for the initial release](docs/release/CHANGES_FOR_INITIAL_RELEASE.md)

## Supported and unsupported behavior

Jester-style routing, response macros and exception handlers are retained
where practical. Intentional security-related behavior changes are described
in the migration guide. This release does not implement static HTTP Range
(206/If-Range) or chunk extensions, and does not guarantee rejection of
LF-only line endings in the request parser.

## License and provenance

MIT-licensed, based on the work of Dominik Picheta and subsequent Jesterfork
contributors. Preserve the original copyright notices and `license.txt`.
