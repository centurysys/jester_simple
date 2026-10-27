# Step 9 request origin trust fixture (loopback only).
import std/net
import jestersimple

settings:
  port = Port(5488)
  bindAddr = "127.0.0.1"
  trustedProxies = @["127.0.0.1/32"]
  allowedHosts = @["gw.example.test"]

routes:
  get "/inspect":
    let current = request.ip & "|" & $request.secure & "|" &
      request.host & "|" & $request.port & "|" &
      request.makeUri("/next")
    resp current

  get "/ping":
    resp "pong"
