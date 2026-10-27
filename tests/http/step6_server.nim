# Step 6 isolated test fixture: short deadlines make resource tests fast.
import std/net
import jestersimple

settings:
  port = Port(5482)
  bindAddr = "127.0.0.1"
  maxBody = 64 * 1024
  maxConnections = 3
  maxHeaderBytes = 1024
  maxHeaderFields = 12
  headerTimeoutMs = 600
  bodyTimeoutMs = 800
  keepAliveTimeoutMs = 500

routes:
  get "/step6/ping":
    resp "pong"

  post "/step6/body":
    resp $request.body.len
