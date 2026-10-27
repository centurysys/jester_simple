# Step 13: confined static files; test assets are created by step13_probe.py.
import std/[net, os]
import jestersimple

settings:
  port = Port(5494)
  bindAddr = "127.0.0.1"
  staticDir = getEnv("STEP13_STATIC_ROOT")

routes:
  get "/ping":
    resp "pong"
