# JS-07: reject unrestricted trustedProxies before opening a listener.
import std/[os, net, strutils]
import jestersimple

# ------------------------------------------------------------------------------
# Exercise the actual serve() startup validation for forbidden proxy networks.
# ------------------------------------------------------------------------------
proc main() =
  if paramCount() != 1:
    quit("Usage: js07_startup <ipv4|ipv6|ipv4-padded|ipv6-padded>", 2)

  let kind = paramStr(1)
  let network =
    case kind
    of "ipv4": "0.0.0.0/0"
    of "ipv6": "::/0"
    of "ipv4-padded": "198.51.100.2/000"
    of "ipv6-padded": "2001:db8::1/00"
    else:
      quit("Invalid JS-07 test case: " & kind, 2)

  var app = initJester(newSettings(bindAddr = "127.0.0.1",
    port = Port(0), trustedProxies = @[network]))
  try:
    app.serve()
    quit("JS-07 unexpectedly returned from serve()", 1)
  except ValueError:
    let message = getCurrentExceptionMsg()
    if message != "Unrestricted trusted proxy CIDR is not allowed":
      quit("JS-07 unexpected validation error: " & message, 1)
    echo "JS07_STARTUP_REJECTED:" & kind

main()
