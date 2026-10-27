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
