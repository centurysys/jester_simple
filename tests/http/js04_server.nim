# JS-04: HTTP Upgrade ownership and connection lifecycle regression server.
# Uses a synthetic 101 response, not an RFC 6455 WebSocket handshake.
import std/[asyncnet, net, os, strutils]
import jestersimple
import jestersimple/private/httptransport as transport

const
  SwitchResponse = "HTTP/1.1 101 Switching Protocols\c\L" &
    "Connection: Upgrade\c\L" &
    "Upgrade: js04-test\c\L\c\L"

settings:
  port = Port(parseInt(getEnv("JS04_PORT", "5534")))
  bindAddr = "127.0.0.1"
  maxConnections = 2
  keepAliveTimeoutMs = 1500

routes:
  get "/ping":
    resp "pong"

  get "/plain":
    # A client-offered Connection: Upgrade cannot by itself switch protocols.
    resp "plain"

  get "/upgrade":
    if not transport.hasConnectionToken(
        request.headers.getOrDefault("Connection"), "upgrade") or
        cmpIgnoreCase(request.headers.getOrDefault("Upgrade"),
                      "js04-test") != 0:
      resp Http400, "invalid-upgrade"
    else:
      enableRawMode
      let client = request.beginUpgrade()
      await client.send(SwitchResponse)
      # The route Future owns the session lifetime. It must read peer EOF.
      while true:
        let command = await client.recv(1)
        if command.len == 0 or command == "Q":
          break
        await client.send("E" & command)

  get "/upgrade-error":
    enableRawMode
    let client = request.beginUpgrade()
    await client.send(SwitchResponse)
    raise newException(ValueError, "JS04 deliberate post-101 exception")
