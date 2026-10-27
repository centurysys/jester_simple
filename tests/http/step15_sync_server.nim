# Step 15: single vs double synchronous matcher equivalence.
# Build with -d:step15Multi to exercise the general dispatcher.
import std/[net, os]
import jestersimple

when defined(step15Multi):
  const Step15Port = 5497
else:
  const Step15Port = 5496

settings:
  port = Port(Step15Port)
  bindAddr = "127.0.0.1"
  staticDir = getEnv("STEP15_STATIC_ROOT")

router primary:
  get "/ok":
    resp "hello"

  get "/empty403":
    resp Http403

  get "/empty500":
    resp Http500

  get "/empty404":
    resp Http404

  get "/halt403":
    halt Http403, "explicit forbidden"

  get "/halt500":
    halt Http500, "explicit failure"

  get "/pass":
    pass()

  get "/pass":
    resp "passed"

  get "/redirect":
    redirect "/ok"

  get "/raw":
    enableRawMode
    request.sendHeaders(Http200, @({"Content-Type": "text/plain",
                                    "Content-Length": "9"}))
    request.send("raw-bytes")

  get "/exception":
    raise newException(ValueError, "STEP15_PRIVATE_TOKEN")

  get "/handler-fails":
    raise newException(IOError, "STEP15_HANDLER_TOKEN")

  get "/no-content":
    resp Http204

  error Http403:
    resp Http403, "custom forbidden"

  error Http500:
    resp Http500, "custom server error"

  error ValueError:
    resp Http409, "custom exception"

  error IOError:
    raise newException(ValueError, "STEP15_INTERNAL_TOKEN")

when defined(step15Multi):
  # This router is deliberately registered after primary. Its presence
  # forces the normal dispatch path without changing shared test routes.
  router secondary:
    get "/secondary-only":
      resp "secondary"

  var app = initJester(primary, settings)
  app.register(secondary.matcher)
  app.register(secondary.errorHandler)
  serve(app)
else:
  var app = initJester(primary, settings)
  serve(app)
