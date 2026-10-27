# Copyright (C) 2026
# MIT License - See license.txt.
# Same route definition is compiled against both HTTP frameworks.

import std/[json, os]
from std/net import Port

when defined(step17Legacy):
  import jesterfork
else:
  import jestersimple

settings:
  port = Port(5517)
  bindAddr = "127.0.0.1"
  staticDir = getEnv("JESTER_STEP17_STATIC_DIR", "tests/public")

routes:
  get "/bench/plain":
    resp "OK"

  get "/bench/json":
    let payload = %*{"status": "ok", "count": 42}
    resp payload

  get "/bench/query":
    resp request.query

  post "/bench/echo":
    resp request.body
