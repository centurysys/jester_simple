# JS-08 loopback integration fixture for explicit and default allowedHosts.
import std/[net, os, strformat, strutils]
import jestersimple

let policy = getEnv("JS08_POLICY", "strict")

settings:
  port = Port(parseInt(getEnv("JS08_PORT", "5558")))
  bindAddr = "127.0.0.1"
  trustedProxies = @["127.0.0.1/32"]
  allowedHosts = (if policy == "default": @[] else: @["gw.example.test"])
  publicBaseUrl = (if policy == "public":
    "https://fixed.example.test:8443" else: "")

routes:
  get "/inspect":
    let current = &"{request.ip}|{request.secure}|{request.host}|{request.port}|" &
      request.makeUri("/next")
    resp current

  get "/ping":
    resp "pong"
