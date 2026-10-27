# HTTP Upgrade ownership and output contract (JS-03)

Jester Simple provides an HTTP transport reservation API. It does **not**
validate WebSocket handshakes or implement any WebSocket frames.

## Initiating an upgrade

1. Validate the HTTP request and planned 101 handshake fully in the application
   or protocol adapter. Errors that require an HTTP 4xx must occur **before**
   calling `beginUpgrade()`.
2. In a route using `enableRawMode`, call `request.beginUpgrade()` before
   writing the first byte of HTTP 101. This atomically reserves the existing
   connection for an upgraded protocol and returns its `AsyncSocket`.
3. Write the 101 handshake directly to that returned socket and await the
   upgraded session in the same route Future. Do **not** detach the session
   with `asyncCheck` and return from the route. The route must use
   `enableRawMode` so no normal HTTP response is appended.
4. If handshake transmission or protocol processing fails after reservation,
   close the connection. Jester Simple must never add a second HTTP status.

Once `beginUpgrade` succeeds, even if no 101 bytes were sent, the connection
cannot return to Managed or queued Raw HTTP mode. The state is intentionally
irreversible until the connection is closed. Both high-level and native
`Request` copies share this state.

## Ownership

The socket remains owned by Jester Simple's `processClient`. The adapter only
borrows it while its route Future is alive. When the route returns or fails,
the HTTP transport closes it and releases the connection slot. The adapter
must not create a second wrapper or register the same socket a second time.

The public transport state checks are `responseStarted` and `upgradeStarted` on
the native request, plus `upgradeStarted` on the high-level request. Native
Managed response APIs, raw queued sends and the high-level Managed response
path enforce the reservation. Direct access to `native.client.send` is not
interceptable; an adapter must use the reserved socket responsibly.

## Remaining verification

JS-04 verifies route-owned session lifetime, Connection token parsing,
connection-slot reclamation, and final socket close. The transport recognizes
`Connection` options as complete comma-separated tokens (ASCII case insensitive),
not substrings. A client sending `Connection: Upgrade` does not by itself
activate an upgraded protocol: only `beginUpgrade()` does. An unaccepted Upgrade
request can receive an ordinary HTTP response and retain HTTP/1.1 keep-alive.
On HTTP/1.1, a `close` token overrides other tokens; on HTTP/1.0, an explicit
`keep-alive` token is required and `close` still takes precedence.
JS-05/06 will introduce deadlines for ordinary HTTP output without applying
short-lived HTTP response deadlines to upgraded sessions. WebSocket handshake
rules, frame validation and ping/idle timeouts belong in `ws`.

## Managed send deadline (JS-05)

Jester Simple now applies `managedSendTimeoutMs` (default `15000`) to each
transport-managed socket send: `respond`, `respondHeaders` (including its
optional first body chunk), and the native `sendHeaders`. A timeout or socket
error closes the transport-owned connection; the route cannot write a second
HTTP error response after sending has started. The timeout is configured using
`settings:` or `newSettings(managedSendTimeoutMs = ...)`. Values below 1 ms
are clamped to 1 ms by the transport; disabling this limit is not supported.

The timeout is **not** a whole-request or whole-response deadline. It does not
cover route computation, queued raw writes (which have their own limit), or
subsequent direct socket writes by static-file streaming code. Those operations
are examined separately in JS-06. `withTimeout` does not cancel a pending
`AsyncSocket.send` Future, so timeout handling closes the socket rather than
waiting indefinitely for that Future. A pending send may retain its message
buffer until the async runtime releases it; resource tests must distinguish
high-water RSS from leaked connections.

An explicitly upgraded connection does not enter any Managed response path, so
this deadline cannot terminate a valid long-lived upgraded session. WebSocket
handshake/frame and idle/heartbeat policies belong to the protocol adapter.

## JS-06 response-start and streaming budgets

The transport has three distinct response-related budgets:

- `managedSendTimeoutMs` (default 15,000): maximum wait per managed socket
  send; existing semantics from JS-05.
- `responseStartTimeoutMs` (default 15,000): maximum time a request may remain
  in the pre-response phase while its route Future is pending. On expiry the
  transport closes the socket, marks output aborted and releases its connection
  slot. This is **not** preemptive cancellation: application Futures may still
  execute after the client connection is gone. Application code must honor
  cancellation/stop conditions itself when doing substantial work.
- `streamTotalTimeoutMs` (default 60,000): elapsed budget from the initial
  header send to completion of managed streamed body chunks. Each chunk also
  uses the Managed send timeout, bounded by the remaining stream budget.

Once a route starts a Managed/Raw response or calls `beginUpgrade()`, the
response-start budget no longer governs its Future. The transport continues
owning upgraded sockets and closes them after the route Future completes.
Raw writes retain their own queue limits and per-write timeout. WebSocket
heartbeat, frame, and idle deadlines remain the ws library's responsibility.

The `sendStreamChunk` transport API is for **awaited, ordered** chunks after
`respondHeaders`. It refuses concurrent calls and chunks larger than 64KiB.
The built-in pinned static-file path streams at 16KiB per chunk and now uses
this API. Do not call a separate `client.send` concurrently with a managed
stream on the same socket.

A route that starts an arbitrary long-running custom Raw response is not
subject to the Managed stream total deadline. Such routes must implement
application-specific bounds; this step does not claim general cancellation
of arbitrary application work.
