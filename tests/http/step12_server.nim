# Step 12: raw send serialization and backpressure fixture, localhost only.
import std/[net, strutils]
import jestersimple

const
  SlowPayloadSize = 16 * 1024 * 1024
  AsyncPayloadSize = 512 * 1024

settings:
  port = Port(5492)
  bindAddr = "127.0.0.1"

routes:
  get "/ping":
    resp "pong"

  get "/legacy":
    enableRawMode
    request.sendHeaders(Http200, @({"Content-Type": "text/plain",
                                    "Content-Length": "12"}))
    request.send("abc")
    request.send("def")
    request.send("ghi")
    request.send("jkl")

  get "/async":
    enableRawMode
    # Keep the request payload local: routes compile into GC-safe handlers.
    let payload = repeat("aB09", AsyncPayloadSize div 4)
    request.sendHeaders(Http200, @({"Content-Type": "application/octet-stream",
                                    "Content-Length": $AsyncPayloadSize}))
    await request.sendAsync(payload)

  get "/mixed":
    enableRawMode
    request.sendHeaders(Http200, @({"Content-Type": "text/plain",
                                    "Content-Length": "10"}))
    request.send("0123")
    await request.sendAsync("456789")

  get "/overflow":
    enableRawMode
    request.sendHeaders(Http200, @({"Content-Type": "application/octet-stream",
                                    "Content-Length": "262145"}))
    # Legacy, synchronous send must refuse an unbounded queued write.
    # Since a status line may already be queued, the framework must close
    # rather than append a second HTTP error response.
    request.send(repeat("x", 262145))

  get "/without-raw":
    request.sendHeaders(Http200, @({"Content-Type": "text/plain",
                                    "Content-Length": "4"}))
    request.send("raw!")
    # Deliberately omit enableRawMode to test double-response prevention.

  get "/disconnect":
    enableRawMode
    request.sendHeaders(Http200, @({"Content-Type": "application/octet-stream",
                                    "Content-Length": $SlowPayloadSize}))
    for i in 0 ..< 1024:
      await request.sendAsync(repeat("z", 16 * 1024))
