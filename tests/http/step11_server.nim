# Step 11: isolated multipart/form-data fixture, localhost only.
import std/[net, json, strtabs, tables]
import jestersimple

settings:
  port = Port(5491)
  bindAddr = "127.0.0.1"
  maxBody = 65536

routes:
  get "/ping":
    resp "pong"

  post "/upload":
    let parts = request.formData
    var doc = newJObject()
    for key, part in parts.pairs:
      var item = newJObject()
      item["body"] = newJString(part.body)
      item["filename"] = newJString(part.fields.getOrDefault("filename"))
      item["contentType"] = newJString(part.fields.getOrDefault("Content-Type"))
      doc[key] = item
    resp $doc

  post "/ignored":
    # Multipart validation must happen even if the route does not read it.
    resp "ignored"
