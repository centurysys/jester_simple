# Copyright (C) 2026
# MIT License - See license.txt in the repository.
# Baseline-only application: does not change the framework implementation.

import std/[json, os]
from std/net import Port
import jestersimple

const BaselinePort = Port(5480)

settings:
  port = BaselinePort
  bindAddr = "127.0.0.1"
  staticDir = getEnv("JESTER_BASELINE_STATIC_DIR", "tests/public")

routes:
  get "/baseline/plain":
    resp "OK"

  get "/baseline/json":
    let payload = %*{"status": "ok", "count": 42}
    resp payload

  get "/baseline/query":
    resp request.query

  get "/baseline/params":
    resp request.params.getOrDefault("value", "")

  post "/baseline/echo":
    resp request.body
