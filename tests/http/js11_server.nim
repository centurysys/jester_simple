# JS-11: startup Settings snapshot and initialization error recovery.
import std/[asyncdispatch, atomics, net, os, strutils]
import jestersimple
import jestersimple/private/utils

# The router's matcher is GC-safe. Only atomic flags are shared with it;
# changes to the caller-owned Settings happen outside the route callback.
var mutationRequested: Atomic[bool]
var mutationCompleted: Atomic[bool]

# ------------------------------------------------------------------------------
# API: Exercise live settings without referring to caller-owned global state.
# ------------------------------------------------------------------------------
router js11Routes:
  get "/inspect":
    resp request.host & "|" & request.makeUri("/next")

  get "/mutate-external":
    mutationRequested.store(true)
    for attempt in 0 ..< 100:
      if mutationCompleted.load():
        break
      await sleepAsync(10)
    if mutationCompleted.load():
      resp "mutated-external"
    else:
      resp Http500, "external-mutation-timeout"

  get "/poison-internal":
    # A route can still mutate the live Settings (legacy API contract).
    # Force a ValueError from parseInt in resolveOrigin on the next request.
    request.settings.publicBaseUrl = "https://example.test:not-a-port"
    resp "mutated-internal"

  get "/ping":
    resp "pong"

# ------------------------------------------------------------------------------
# API: Mutate the caller's Settings from outside the GC-safe router.
# ------------------------------------------------------------------------------
proc mutateCallerSettings(source: Settings) {.async.} =
  while not mutationRequested.load():
    await sleepAsync(10)
  source.allowedHosts = @["evil.example.test"]
  source.trustedProxies = @["0.0.0.0/0"]
  mutationCompleted.store(true)

when isMainModule:
  let source = newSettings(
    port = Port(parseInt(getEnv("JS11_PORT", "5551"))),
    bindAddr = "127.0.0.1",
    allowedHosts = @["gw.example.test"],
    maxConnections = 4,
    keepAliveTimeoutMs = 1500
  )
  var server = initJester(js11Routes, source)
  asyncCheck mutateCallerSettings(source)
  server.serve()
