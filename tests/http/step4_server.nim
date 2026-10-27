# Copyright (C) 2026
# MIT License - See license.txt in the repository.
# HTTP transport probe only. The framework is intentionally unmodified.

import std/net
import jestersimple

const
  ProbePort = Port(5481)
  ProbeMaxBody = 64 * 1024

settings:
  port = ProbePort
  bindAddr = "127.0.0.1"
  maxBody = ProbeMaxBody

routes:
  get "/step4/ping":
    resp "pong"

  post "/step4/body":
    resp $request.body.len
