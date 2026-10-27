# JS-05: Managed HTTP socket-send deadline regression server.
# All endpoints bind to loopback; no real WebSocket framing is used.
import std/[asyncnet, net, os, strutils]
import jestersimple
import jestersimple/private/httptransport as transport

const
  LargeBodyBytes = 16 * 1024 * 1024
  SwitchResponse = "HTTP/1.1 101 Switching Protocols\c\L" &
    "Connection: Upgrade\c\L" &
    "Upgrade: js05-test\c\L\c\L"

settings:
  port = Port(parseInt(getEnv("JS05_PORT", "5535")))
  bindAddr = "127.0.0.1"
  maxConnections = 1
  managedSendTimeoutMs = parseInt(getEnv("JS05_SEND_TIMEOUT_MS", "400"))
  keepAliveTimeoutMs = 1500

routes:
  get "/ping":
    resp "pong"

  get "/head":
    resp "head-test-content"

  head "/head":
    resp "head-test-content"

  get "/large":
    resp repeat('x', LargeBodyBytes)

  get "/native-headers":
    enableRawMode
    await request.getNativeReq.respondHeaders(
      Http200, newHttpHeaders([("Content-Length", "4"),
                               ("Connection", "close")]), "data")

  get "/native-large":
    enableRawMode
    await request.getNativeReq.respondHeaders(
      Http200, newHttpHeaders([("Content-Length", $LargeBodyBytes),
                               ("Connection", "close")]),
      repeat('y', LargeBodyBytes))

  get "/upgrade":
    enableRawMode
    let client = request.beginUpgrade()
    await client.send(SwitchResponse)
    # Remain active for longer than the Managed HTTP send deadline.
    await sleepAsync(900)
    await client.send("Z")
    discard await client.recv(1)
