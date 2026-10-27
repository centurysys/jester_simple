# JS-01: Managed HEAD response regression server (loopback only).
import std/net
import jestersimple

const
  Js01Port = 5511
  ManagedBody = "js01-managed-response"
  ErrorBody = "js01-explicit-error"
  ExplicitBody = "js01-explicit-length"
  InvalidBody = "js01-invalid-length"

settings:
  port = Port(Js01Port)
  bindAddr = "127.0.0.1"

# ------------------------------------------------------------------------------
# Define the same routes for single, multiple and asynchronous matcher tests.
# ------------------------------------------------------------------------------
router primary:
  get "/ping":
    resp "pong"

  get "/managed":
    resp Http200, {"Content-Type": "text/plain"}, ManagedBody

  head "/managed":
    resp Http200, {"Content-Type": "text/plain"}, ManagedBody

  get "/explicit":
    resp Http200, {
      "Content-Type": "text/plain", "Content-Length": $ExplicitBody.len
    }, ExplicitBody

  head "/explicit":
    resp Http200, {
      "Content-Type": "text/plain", "Content-Length": $ExplicitBody.len
    }, ExplicitBody

  get "/empty":
    resp Http200, {"Content-Type": "text/plain"}, ""

  head "/empty":
    resp Http200, {"Content-Type": "text/plain"}, ""

  get "/error":
    resp Http404, {"Content-Type": "text/plain"}, ErrorBody

  head "/error":
    resp Http404, {"Content-Type": "text/plain"}, ErrorBody

  get "/generated404":
    resp Http404

  head "/generated404":
    resp Http404

  get "/invalid-response":
    # Framework validation generates a managed 500 with a fixed error page.
    resp Http200, {
      "Content-Type": "text/plain", "Content-Length": "0"
    }, InvalidBody

  head "/invalid-response":
    resp Http200, {
      "Content-Type": "text/plain", "Content-Length": "0"
    }, InvalidBody

# ------------------------------------------------------------------------------
# Select the same route behavior through each dispatch implementation.
# ------------------------------------------------------------------------------
when defined(js01Async):
  router asyncPrimary:
    {.async.}
    # No prefix is the normal two-element extend form.
    extend primary

  var app = initJester(asyncPrimary, settings)
elif defined(js01Multi):
  router secondary:
    get "/secondary-only":
      resp "secondary"

  var app = initJester(primary, settings)
  app.register(secondary.matcher)
  app.register(secondary.errorHandler)
else:
  var app = initJester(primary, settings)

serve(app)
