# Step 7: synchronous single-matcher fast-path exception fixture.
import std/net
import jestersimple

settings:
  port = Port(5484)
  bindAddr = "127.0.0.1"
  appName = "/app"

routes:
  get "/step7/ping":
    resp "pong"

  get "/step7/sync":
    raise newException(ValueError,
      "SYNC_FAST_PATH_SECRET_<script>alert(1)</script>")
