# JS-09: static dotfile denial and application-selected sendFile compatibility.
# This is a loopback-only test fixture, not an authenticated file service.
import std/[net, os, strutils]
import jestersimple

settings:
  port = Port(parseInt(getEnv("JS09_PORT", "5559")))
  bindAddr = "127.0.0.1"
  staticDir = getEnv("JS09_STATIC_ROOT")

routes:
  get "/ping":
    resp "pong"

  get "/explicit-private":
    # Deliberately chosen by the application, outside the public staticDir.
    sendFile(getEnv("JS09_EXPLICIT_FILE"))
