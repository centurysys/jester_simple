# Step 7: isolated exception disclosure and appName boundary fixture.
import std/net
import jestersimple

type
  CustomFailure = object of CatchableError
  FailingHandler = object of CatchableError

settings:
  port = Port(5483)
  bindAddr = "127.0.0.1"
  appName = "/app"

routes:
  get "/":
    resp "mounted root"

  get "/step7/ping":
    resp "pong"

  get "/step7/sync":
    raise newException(ValueError,
      "SYNC_PRIVATE_TOKEN_<script>alert(1)</script>")

  get "/step7/async":
    await sleepAsync(1)
    raise newException(ValueError,
      "ASYNC_PRIVATE_TOKEN_<img src=x onerror=alert(1)>")

  get "/step7/custom":
    raise newException(CustomFailure, "custom handler detail")

  get "/step7/handler-fails":
    raise newException(FailingHandler, "original handler detail")

  get "/step7/forbidden":
    resp Http403

  get "/step7/explicit":
    halt Http502, "explicit application response"

  error CustomFailure:
    resp Http409, "custom handler preserved"

  error FailingHandler:
    raise newException(ValueError, "HANDLER_PRIVATE_TOKEN")

  error Http403:
    resp Http403, "custom forbidden response"
