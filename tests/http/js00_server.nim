# JS-00: Baseline-only HTTP regression fixture; listen on loopback.
# This file intentionally reproduces pre-fix behavior. Do not use in production.
import std/[asyncnet, net, strutils]
import jestersimple

const
  Js00Port = 5510
  ManagedHeadBody = "js00-managed-head-body"
  ManagedErrorBody = "js00-managed-error-body"
  LargeResponseSize = 8 * 1024 * 1024

settings:
  port = Port(Js00Port)
  bindAddr = "127.0.0.1"

routes:
  get "/ping":
    resp "pong"

  get "/managed-head":
    resp Http200, {"Content-Type": "text/plain"}, ManagedHeadBody

  head "/managed-head":
    resp Http200, {"Content-Type": "text/plain"}, ManagedHeadBody

  head "/managed-error":
    resp Http404, {"Content-Type": "text/plain"}, ManagedErrorBody

  get "/cookie-managed":
    setCookie("session", "JS00_MANAGED_COOKIE_SECRET_781", httpOnly=true)
    setCookie("theme", "JS00_SECOND_COOKIE_SECRET_782", path="/")
    resp "managed-cookie-ok"

  get "/cookie-raw":
    enableRawMode
    request.sendHeaders(Http200, @({
      "Content-Type": "text/plain",
      "Content-Length": "2",
      "Set-Cookie": "raw=JS00_RAW_COOKIE_SECRET_783; HttpOnly"
    }))
    await request.sendAsync("ok")

  get "/managed-large":
    # Deliberately large one-shot managed response for a non-reading client.
    # Use only with the local baseline probe, one connection at a time.
    resp repeat("x", LargeResponseSize)

  get "/upgrade-exception":
    # Simulates a ws adapter that sends 101 directly on AsyncSocket.
    # NOT a complete RFC 6455 handshake: this is a transport-state probe.
    enableRawMode
    await request.getNativeReq().client.send(
      "HTTP/1.1 101 Switching Protocols\c\L" &
      "Upgrade: websocket\c\L" &
      "Connection: Upgrade\c\L\c\L")
    raise newException(ValueError, "JS00_UPGRADE_TEST_EXCEPTION")

  get "/upgrade-lifetime":
    # The callback must retain the socket until the simulated session ends.
    # It deliberately sends no WebSocket frames.
    enableRawMode
    await request.getNativeReq().client.send(
      "HTTP/1.1 101 Switching Protocols\c\L" &
      "Upgrade: websocket\c\L" &
      "Connection: Upgrade\c\L\c\L")
    await sleepAsync(800)
