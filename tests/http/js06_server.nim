# JS-06: bounded static streaming, response-start deadline, ORC observations.
# Test-only HTTP server. The Upgrade endpoint is a synthetic 101, not RFC 6455.
import std/[asyncnet, net, os, strutils]
import jestersimple
import jestersimple/private/httptransport as transport

const
  LargeBodyBytes = 16 * 1024 * 1024
  Synthetic101 = "HTTP/1.1 101 Switching Protocols\c\L" &
    "Connection: Upgrade\c\L" &
    "Upgrade: js06-test\c\L\c\L"

# ------------------------------------------------------------------------------
# Probe whether this compiler configuration exposes explicit ORC collection.
# ------------------------------------------------------------------------------
proc collectForProbe(): string =
  when declared(GC_runOrc):
    GC_runOrc()
    result = "GC_runOrc"
  else:
    result = "unavailable"

settings:
  port = Port(parseInt(getEnv("JS06_PORT", "5536")))
  bindAddr = "127.0.0.1"
  staticDir = getEnv("JS06_PUBLIC_DIR", "/tmp/js06-nonexistent")
  maxConnections = 1
  managedSendTimeoutMs = 400
  responseStartTimeoutMs = 350
  streamTotalTimeoutMs = 1200
  keepAliveTimeoutMs = 1500

routes:
  get "/ping":
    resp "pong"

  get "/silent":
    # No output until after responseStartTimeoutMs; a late response is rejected.
    await sleepAsync(1700)
    resp "late-output-must-not-appear"

  get "/managed-large":
    resp repeat('m', LargeBodyBytes)

  get "/collect":
    resp collectForProbe()

  get "/native-stream":
    enableRawMode
    let native = request.getNativeReq()
    await native.respondHeaders(Http200,
      newHttpHeaders([("Content-Length", "4"), ("Connection", "close")]))
    await native.sendStreamChunk("data")

  get "/native-expired":
    enableRawMode
    let native = request.getNativeReq()
    await native.respondHeaders(Http200,
      newHttpHeaders([("Content-Length", "4"), ("Connection", "close")]))
    # Must hit the total-stream limit even without another socket send.
    await sleepAsync(2000)
    await native.sendStreamChunk("late")

  get "/upgrade":
    enableRawMode
    let client = request.beginUpgrade()
    await client.send(Synthetic101)
    # The response-start deadline is 350ms; a live upgraded session is exempt.
    await sleepAsync(900)
    await client.send("Z")
    discard await client.recv(1)
