# Step 15: equivalent asynchronous matcher for dispatch comparisons.
import std/[net, os]
import jestersimple

settings:
  port = Port(5498)
  bindAddr = "127.0.0.1"
  staticDir = getEnv("STEP15_STATIC_ROOT")

router asyncRoutes:
  get "/ok":
    await sleepAsync(1)
    resp "hello"

  get "/empty403":
    await sleepAsync(1)
    resp Http403

  get "/empty500":
    await sleepAsync(1)
    resp Http500

  get "/empty404":
    await sleepAsync(1)
    resp Http404

  get "/halt403":
    await sleepAsync(1)
    halt Http403, "explicit forbidden"

  get "/halt500":
    await sleepAsync(1)
    halt Http500, "explicit failure"

  get "/pass":
    await sleepAsync(1)
    pass()

  get "/pass":
    await sleepAsync(1)
    resp "passed"

  get "/redirect":
    await sleepAsync(1)
    redirect "/ok"

  get "/raw":
    await sleepAsync(1)
    enableRawMode
    request.sendHeaders(Http200, @({"Content-Type": "text/plain",
                                    "Content-Length": "9"}))
    await request.sendAsync("raw-bytes")

  get "/exception":
    await sleepAsync(1)
    raise newException(ValueError, "STEP15_PRIVATE_TOKEN")

  get "/handler-fails":
    await sleepAsync(1)
    raise newException(IOError, "STEP15_HANDLER_TOKEN")

  get "/no-content":
    await sleepAsync(1)
    resp Http204

  error Http403:
    resp Http403, "custom forbidden"

  error Http500:
    resp Http500, "custom server error"

  error ValueError:
    resp Http409, "custom exception"

  error IOError:
    raise newException(ValueError, "STEP15_INTERNAL_TOKEN")

var app = initJester(asyncRoutes, settings)
serve(app)
