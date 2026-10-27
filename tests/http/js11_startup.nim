# JS-11: invalid limits must reject startup before opening the listener.
import std/[os, net]
import jestersimple

proc main() =
  if paramCount() != 1:
    quit("Usage: js11_startup <static|connections|timeout|body|proxy>", 2)

  let settings = newSettings(port = Port(0), bindAddr = "127.0.0.1")
  case paramStr(1)
  of "static": settings.staticDir = ""
  of "connections": settings.maxConnections = 0
  of "timeout": settings.responseStartTimeoutMs = 0
  of "body": settings.maxBody = -1
  of "proxy": settings.trustedProxies = @["0.0.0.0/0"]
  else: quit("Invalid case", 2)

  var server = initJester(settings)
  try:
    server.serve()
    quit("Unexpected server start", 1)
  except ValueError:
    echo "JS11_STARTUP_REJECTED: " & paramStr(1)

main()
