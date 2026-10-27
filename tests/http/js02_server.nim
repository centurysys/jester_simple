# JS-02: Response header log secrecy regression (loopback only).
import std/[net, os, strutils]
import jestersimple

settings:
  port = Port(parseInt(getEnv("JS02_PORT", "5532")))
  bindAddr = "127.0.0.1"

routes:
  get "/ping":
    resp "pong"

  get "/managed":
    setCookie("sid", "JS02_MANAGED_COOKIE_A", httpOnly=true)
    setCookie("theme", "JS02_MANAGED_COOKIE_B", path="/")
    setHeader(responseHeaders, "Authorization", "Bearer JS02_MANAGED_AUTH")
    setHeader(responseHeaders, "X-Api-Key", "JS02_MANAGED_API_KEY")
    setHeader(responseHeaders, "X-Custom-Metadata", "JS02_MANAGED_CUSTOM")
    setHeader(responseHeaders, "Location", "https://example.invalid/?id=JS02_MANAGED_LOCATION")
    resp "managed-ok"

  get "/raw":
    enableRawMode
    request.sendHeaders(Http200, @({
      "Content-Type": "text/plain",
      "Content-Length": "6",
      "Set-Cookie": "sid=JS02_RAW_COOKIE_A; HttpOnly",
      "set-cookie": "theme=JS02_RAW_COOKIE_B; Path=/",
      "Proxy-Authorization": "Basic JS02_RAW_PROXY_AUTH",
      "WWW-Authenticate": "Bearer realm=JS02_RAW_AUTH_CHALLENGE",
      "X-Api-Key": "JS02_RAW_API_KEY",
      "X-Custom-Metadata": "JS02_RAW_CUSTOM"
    }))
    await request.sendAsync("raw-ok")

