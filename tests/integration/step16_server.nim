# Step 16: integration fixture combining previously hardened HTTP features.
# This executable only listens on loopback and creates no persistent files.
import std/[net, os, tables]
import jestersimple

settings:
  port = Port(5499)
  bindAddr = "127.0.0.1"
  staticDir = getEnv("STEP16_STATIC_ROOT")
  maxBody = 65536

routes:
  get "/ping":
    resp "pong"

  get "/origin":
    # Untrusted forwarded headers must not change the socket peer or scheme.
    resp request.ip & "|" & $request.secure & "|" &
      request.makeUri("/ping")

  get "/query":
    resp request.params.getOrDefault("v")

  post "/form":
    resp request.params.getOrDefault("v")

  post "/upload":
    let parts = request.formData
    if parts.hasKey("note"):
      resp parts["note"].body
    else:
      resp Http400, "missing note"

  get "/cookies":
    setCookie("sid", "one", httpOnly=true)
    setCookie("theme", "light", path="/")
    resp request.params.getOrDefault("v")

  get "/cookies-mixed":
    setHeader(responseHeaders, "set-cookie", "legacy=1")
    setCookie("second", "2")
    resp "mixed"

  get "/invalid-cookie":
    setCookie("sid", "bad; value")
    resp "STEP16_NEVER_SEND_COOKIE"

  get "/redirect":
    redirect "/ping"

  get "/exception":
    raise newException(ValueError, "STEP16_PRIVATE_EXCEPTION")

  get "/raw":
    enableRawMode
    request.sendHeaders(Http200, @({"Content-Type": "text/plain",
                                    "Content-Length": "12"}))
    await request.sendAsync("raw-response")
