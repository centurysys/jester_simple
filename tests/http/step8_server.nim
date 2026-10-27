# Step 8: loopback-only response header safety fixture.
import std/net
import jestersimple

settings:
  port = Port(5485)
  bindAddr = "127.0.0.1"

routes:
  get "/ping":
    resp "pong"

  get "/normal":
    setHeader(responseHeaders, "X-Test", "safe")
    resp "ok"

  get "/case-replace":
    setHeader(responseHeaders, "x-Case", "old")
    setHeader(responseHeaders, "X-CASE", "new")
    resp "case"

  get "/cookie":
    setCookie("sid", "one", httpOnly=true)
    setCookie("theme", "light", path="/")
    resp "cookies"

  get "/cookie-mixed-case":
    setHeader(responseHeaders, "set-cookie", "legacy=1")
    setCookie("second", "2")
    resp "cookies"

  get "/redirect":
    redirect "/safe", httpStatusCode=Http302

  get "/bad-name":
    setHeader(responseHeaders, "Bad Header", "value")
    resp "NEVER_EXPOSE_THIS"

  get "/bad-value":
    setHeader(responseHeaders, "X-Foo", "safe\c\LInjected: yes")
    resp "NEVER_EXPOSE_THIS"

  get "/bad-redirect":
    redirect "/safe\c\LInjected: yes"

  get "/resp-bad":
    resp Http200, {"X-Foo": "safe\c\LInjected: yes"}, "NEVER_EXPOSE_THIS"

  get "/resp-bad-length":
    resp Http200, {"Content-Length": "1"}, "wrong length"

  get "/resp-duplicate-length":
    # resp uses setHeader and intentionally replaces existing keys.
    # halt keeps the literal RawHeaders sequence, allowing the duplicate
    # to reach the final response validation layer.
    halt(Http200, {"Content-Length": "2", "content-length": "2"}, "hi")

  get "/resp-transfer-encoding":
    resp Http200, {"Transfer-Encoding": "chunked"}, "hi"

  get "/resp-valid-length":
    resp Http200, {"Content-Length": "2"}, "hi"

  get "/bad-cookie-name":
    setCookie("bad;name", "value")
    resp "NEVER_EXPOSE_THIS"

  get "/bad-cookie-value":
    setCookie("sid", "ok; admin=true")
    resp "NEVER_EXPOSE_THIS"

  get "/bad-cookie-domain":
    setCookie("sid", "ok", domain="example.com; Secure")
    resp "NEVER_EXPOSE_THIS"

  get "/attachment":
    attachment("report\"quoted\\file.txt")
    resp "attached"

  get "/bad-attachment":
    attachment("file\c\LInjected: yes.txt")
    resp "NEVER_EXPOSE_THIS"

  get "/raw-bad":
    request.sendHeaders(Http200, @({"X-Foo": "safe\c\LInjected: yes"}))
    enableRawMode

  get "/raw-valid":
    enableRawMode
    request.send(Http200, @({"Content-Type": "text/plain"}), "hello")
