from std/algorithm import sort
from std/strformat import fmt
from std/strutils import join
import jestersimple

settings:
  port = Port(5454)
  bindAddr = "127.0.0.1"

# ------------------------------------------------------------------------------
# Sort test-only output keys because Table iteration order is unspecified.
# ------------------------------------------------------------------------------
proc sortedKeys[T](params: Table[string, T]): seq[string] =
  for key in params.keys:
    result.add key
  result.sort()

# ------------------------------------------------------------------------------
# Render single-value parameters in a deterministic order for HTTP assertions.
# ------------------------------------------------------------------------------
proc formatParams(params: Table[string, string]): string =
  for key in sortedKeys(params):
    let value = params[key]
    result.add fmt"{key}: {value}"

# ------------------------------------------------------------------------------
# Render multi-value parameters without changing each key's value order.
# ------------------------------------------------------------------------------
proc formatSeqParams(params: Table[string, seq[string]]): string =
  for key in sortedKeys(params):
    let value = params[key].join(",")
    result.add fmt"{key}: {value}"

routes:
  get "/":
    resp Http200
  get "/params":
    let params = params request
    resp formatParams params
  get "/params/@val%23ue":
    let params = params request
    resp formatParams params
  post "/params/@val%23ue":
    let params = params request
    resp formatParams params
  get "/multi":
    let params = paramValuesAsSeq request
    resp formatSeqParams(params)
  get "/@val%23ue":
    let params = paramValuesAsSeq request
    resp formatSeqParams(params)
  post "/@val%23ue":
    let params = paramValuesAsSeq request
    resp formatSeqParams(params)
