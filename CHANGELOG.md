# Jester Simple changelog

## Unreleased — Jesterfork to Jester Simple modernization

This entry describes the changes integrated on the Jesterfork history to form
Jester Simple. The package currently declares version `1.0.0`, inherited from
the pre-release source state; **a separate Jester Simple release/tag and date
have not been asserted here**.

### Supported platform and architecture

- Rename the package and import path to `jestersimple`.
- Target Linux with Nim 2.2.12+ and ORC; remove HTTPBeast, legacy server
  selection and unsupported Windows/macOS paths.
- Retain Jester-style routes, response helpers and essential callback APIs,
  with an `asyncdispatch`-based private HTTP transport.

### Request validation and resource limits

- Reject ambiguous message framing (conflicting Content-Length values,
  Content-Length combined with Transfer-Encoding, and malformed chunking).
- Enforce body-size limits for Content-Length and chunked requests.
- Apply configurable connection, header-size/count and receive-time limits.
- Decode query and form data once and reject invalid encodings/multipart
  boundaries.
- Treat Host and forwarding headers as untrusted unless the request reaches
  the server through an explicitly trusted proxy.

### Response handling and file serving

- Validate outgoing headers and cookie values; preserve multiple Set-Cookie
  response headers.
- Prevent server exception details from appearing in default error pages.
- Align synchronous matcher error behavior with asynchronous/multiple-match
  dispatch, without removing the successful synchronous response path.
- Use Linux `openat` / `O_NOFOLLOW`-based path confinement for static files;
  pin and stream an opened descriptor to prevent path-replacement races.
- Add HEAD and ETag/304 behavior for static transfers; use metadata-derived
  weak ETags instead of per-request MD5 reads.
- Stream files in bounded chunks. Combine response headers and the first
  static body block in a single socket write to avoid small-response stalls.
- Bound queued raw writes and expose `request.sendAsync()` for awaitable writes.

### Tests and operational documentation

- Add HTTP security, API-parity and cross-feature integration regressions for
  Debug and Release configurations, plus a local suite runner.
- Add repeatable Linux performance and resource-footprint measurement tools,
  including comparisons with a legacy Jesterfork source tree.
- Document migration differences, security limitations and release checks.

### Compatibility and limitations

- Change imports from `jesterfork` to `jestersimple` and use Nim 2.2.12+ / ORC
  on Linux; HTTPBeast-specific options are removed.
- Some requests previously accepted are intentionally rejected with 4xx due
  to stricter parsing; invalid application response headers can cause 500.
- Forwarded-origin behavior, symlink policy, and static ETag format differ.
- Static Range/If-Range and chunk extensions are not implemented. See the
  [migration guide](docs/migration/jesterfork_to_jestersimple.md).

## Prior Jester/Jesterfork history

Jester Simple preserves its upstream Git ancestry and license notices, but the
historical 2016–2023 Jester release notes are **not Jester Simple releases**.
For the older changelog, see
[dom96/jester releases](https://github.com/dom96/jester/releases) and the
upstream history in this Git repository.
