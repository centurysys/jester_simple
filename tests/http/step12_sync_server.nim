# A single synchronous matcher exercises the optimized dispatch branch.
import std/net
import jestersimple

settings:
  port = Port(5493)
  bindAddr = "127.0.0.1"

routes:
  get "/":
    enableRawMode
    request.sendHeaders(Http200, @({"Content-Type": "text/plain",
                                    "Content-Length": "4"}))
    request.send("solo")
