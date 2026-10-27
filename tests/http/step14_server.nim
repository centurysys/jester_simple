# Step 14: static HTTP response semantics and bounded streaming (loopback only).
import std/[net, os]
import jestersimple

settings:
  port = Port(5495)
  bindAddr = "127.0.0.1"
  staticDir = getEnv("STEP14_STATIC_ROOT")

routes:
  get "/ping":
    resp "pong"

  get "/explicit":
    # Explicit sendFile retains its application-selected path semantics.
    sendFile(getEnv("STEP14_EXPLICIT_FILE"))
