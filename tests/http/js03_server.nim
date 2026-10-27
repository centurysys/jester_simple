# JS-03: Generic HTTP Upgrade response-state regression server (loopback only).
# This uses a minimal synthetic 101 response; it is NOT an RFC 6455 handshake.
import std/[asyncnet, net, os, strutils]
import jestersimple
import jestersimple/private/httptransport as httptransport

const
  SwitchResponse = "HTTP/1.1 101 Switching Protocols\c\L" &
    "Connection: Upgrade\c\L" &
    "Upgrade: js03-test\c\L\c\L"

settings:
  port = Port(parseInt(getEnv("JS03_PORT", "5533")))
  bindAddr = "127.0.0.1"

routes:
  get "/ping":
    resp "pong"

  get "/reject-before-upgrade":
    # Validation belongs to the caller; no Upgrade reservation is made here.
    resp Http400, "invalid-upgrade"

  get "/upgrade-lifetime":
    enableRawMode
    let client = request.beginUpgrade()
    await client.send(SwitchResponse)
    # The HTTP transport should wait for the route before closing the socket.
    await sleepAsync(250)

  get "/upgrade-exception":
    enableRawMode
    let client = request.beginUpgrade()
    await client.send(SwitchResponse)
    raise newException(ValueError, "js03 deliberate route failure")

  get "/upgrade-duplicate":
    enableRawMode
    let client = request.beginUpgrade()
    await client.send(SwitchResponse)
    try:
      discard request.beginUpgrade()
      await client.send("DUPLICATE_ALLOWED")
    except ValueError:
      await client.send("DUPLICATE_REJECTED")

  get "/upgrade-managed":
    let client = request.beginUpgrade()
    await client.send(SwitchResponse)
    # The router must not append a managed 200 after the 101.
    resp "illegal-managed-body"

  get "/upgrade-raw":
    enableRawMode
    let client = request.beginUpgrade()
    await client.send(SwitchResponse)
    try:
      request.send("illegal-raw-body")
      await client.send("RAW_ALLOWED")
    except ValueError:
      await client.send("RAW_REJECTED")

  get "/upgrade-raw-headers":
    enableRawMode
    let client = request.beginUpgrade()
    await client.send(SwitchResponse)
    try:
      request.sendHeaders(Http200)
      await client.send("RAW_HEADERS_ALLOWED")
    except ValueError:
      await client.send("RAW_HEADERS_REJECTED")

  get "/upgrade-raw-async":
    enableRawMode
    let client = request.beginUpgrade()
    await client.send(SwitchResponse)
    try:
      await request.sendAsync("illegal-raw-async-body")
      await client.send("RAW_ASYNC_ALLOWED")
    except ValueError:
      await client.send("RAW_ASYNC_REJECTED")

  get "/upgrade-copy":
    enableRawMode
    # The copied Request must share the response state with the original.
    let copied = request
    let client = copied.beginUpgrade()
    await client.send(SwitchResponse)
    try:
      request.send("illegal-copy-body")
      await client.send("COPY_ALLOWED")
    except ValueError:
      await client.send("COPY_REJECTED")

  get "/raw-before-upgrade":
    enableRawMode
    request.sendHeaders(Http200, @({
      "Content-Type": "text/plain",
      "Content-Length": "3"
    }))
    request.send("raw")
    # Previously queued raw data must prevent switching protocols.
    discard request.beginUpgrade()

  get "/managed-before-upgrade":
    enableRawMode
    let native = request.getNativeReq()
    await httptransport.respond(native, Http200, "managed")
    # Once an HTTP response starts, Upgrade must not be permitted.
    discard request.beginUpgrade()

  get "/upgrade-reserved-error":
    enableRawMode
    discard request.beginUpgrade()
    # No 101 bytes have been sent, but a fallback HTTP 500 is still illegal.
    raise newException(ValueError, "js03 error after Upgrade reservation")
