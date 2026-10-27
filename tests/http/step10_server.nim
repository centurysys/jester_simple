# Step 10: isolated query/form/path fixture, localhost only.
import std/[net, json, tables]
import jestersimple

settings:
  port = Port(5490)
  bindAddr = "127.0.0.1"

# ------------------------------------------------------------------------------
# JSON output is independent of Table iteration order.
# ------------------------------------------------------------------------------
proc serializeSingle(values: Table[string, string]): string =
  var doc = newJObject()
  for key, value in values:
    doc[key] = newJString(value)
  $doc

proc serializeMultiple(values: Table[string, seq[string]]): string =
  var doc = newJObject()
  for key, value in values:
    var arr = newJArray()
    for item in value:
      arr.add newJString(item)
    doc[key] = arr
  $doc

routes:
  get "/ping":
    resp "pong"

  get "/single":
    resp serializeSingle(request.params)

  post "/single":
    resp serializeSingle(request.params)

  get "/multi":
    resp serializeMultiple(request.paramValuesAsSeq)

  post "/multi":
    resp serializeMultiple(request.paramValuesAsSeq)

  get "/path/@item":
    resp serializeMultiple(request.paramValuesAsSeq)

  get "/raw/@item":
    resp request.pathInfo
