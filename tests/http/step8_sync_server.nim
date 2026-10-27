# Step 8: synchronous single-matcher fast path coverage.
import std/net
import jestersimple

settings:
  port = Port(5486)
  bindAddr = "127.0.0.1"

routes:
  get "/":
    setHeader(responseHeaders, "X-Evil", "safe\LForged: yes")
    resp "NEVER_EXPOSE_THIS"
