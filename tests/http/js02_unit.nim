# JS-02: Test redaction independently of the HTTP router and logger settings.
import std/strutils
import jestersimple/private/headerlogging

# ------------------------------------------------------------------------------
# Unknown headers fail closed; multiple Cookie headers are all redacted.
# ------------------------------------------------------------------------------
let rendered = formatHeadersForLog(@[
  (key: "Set-Cookie", val: "sid=JS02_UNIT_COOKIE_A"),
  (key: "set-cookie", val: "sid=JS02_UNIT_COOKIE_B"),
  (key: "Authorization", val: "Bearer JS02_UNIT_BEARER"),
  (key: "X-Custom-Metadata", val: "JS02_UNIT_CUSTOM"),
  (key: "Location", val: "/?token=JS02_UNIT_LOCATION"),
  (key: "Content-Type", val: "JS02_UNIT_CONTENT_TYPE"),
  (key: "Content-Length", val: "42"),
  (key: "content-length", val: "42x")
])

for secret in [
  "JS02_UNIT_COOKIE_A", "JS02_UNIT_COOKIE_B", "JS02_UNIT_BEARER",
  "JS02_UNIT_CUSTOM", "JS02_UNIT_LOCATION", "JS02_UNIT_CONTENT_TYPE",
  "42x"
]:
  doAssert secret notin rendered, "Response header value leaked: " & secret

doAssert "[REDACTED]" in rendered
doAssert "content-length" in rendered.toLowerAscii()
doAssert "42" in rendered

# Inputs must remain unchanged after formatting.
var original = @[(key: "Set-Cookie", val: "JS02_UNIT_IMMUTABLE")]
discard formatHeadersForLog(original)
doAssert original[0].val == "JS02_UNIT_IMMUTABLE"

echo "PASS JS-02 header logging redaction unit tests"
