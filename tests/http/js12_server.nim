# JS-12: keep-alive URI, line-boundary, and repeated-header regression server.
# Loopback-only; the client sends raw requests to exercise parser semantics.
import std/[net, os, strutils, tables]
import jestersimple

settings:
  port = Port(parseInt(getEnv("JS12_PORT", "5562")))
  bindAddr = "127.0.0.1"
  maxConnections = 8
  maxHeaderBytes = 16 * 1024
  maxHeaderFields = 100
  keepAliveTimeoutMs = 1500

routes:
  get "/ping":
    resp "pong"

  head "/head-check":
    resp "head-response"

  get "/inspect":
    resp request.path & "|" & request.query

  get "/cookies":
    let parsed = request.cookies
    resp parsed.getOrDefault("a", "-") & "|" &
      parsed.getOrDefault("b", "-")

  get "/headers":
    # The probe always supplies two X-Repeat fields and two Connection fields.
    let connection: string = request.headers["Connection"]
    let first = request.headers["X-Repeat", 0]
    let second = request.headers["X-Repeat", 1]
    resp connection & "|" & first & "|" & second
