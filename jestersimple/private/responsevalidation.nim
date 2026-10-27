# HTTP response header validation shared by framework and transport.
# Validate before serializing; do not rewrite untrusted field values.

import std/[strutils, httpcore]

# ------------------------------------------------------------------------------
# HTTP field names are RFC token characters only.
# ------------------------------------------------------------------------------
proc validateHeaderPair*(key, value: string) =
  const extra = {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.',
                 '^', '_', '`', '|', '~'}
  if key.len == 0:
    raise newException(ValueError, "Invalid HTTP response header")
  for c in key:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9'} and c notin extra:
      raise newException(ValueError, "Invalid HTTP response header")
  for c in value:
    if ord(c) < 32 or ord(c) == 127:
      raise newException(ValueError, "Invalid HTTP response header")

# ------------------------------------------------------------------------------
# Parse Content-Length without signs, lists, whitespace or integer overflow.
# ------------------------------------------------------------------------------
proc parseResponseLength(value: string): int =
  if value.len == 0:
    raise newException(ValueError, "Invalid response Content-Length")
  var n = 0
  for c in value:
    if c notin {'0'..'9'}:
      raise newException(ValueError, "Invalid response Content-Length")
    let digit = ord(c) - ord('0')
    if n > (high(int) - digit) div 10:
      raise newException(ValueError, "Invalid response Content-Length")
    n = n * 10 + digit
  return n

# ------------------------------------------------------------------------------
# Reject unowned transfer framing in both managed and raw response headers.
# Body length equality is checked only when a complete body is provided.
# ------------------------------------------------------------------------------
proc checkFraming(key, value: string, seenLength: var bool,
                  bodyLen: int) =
  if cmpIgnoreCase(key, "Transfer-Encoding") == 0:
    raise newException(ValueError, "Unsupported response transfer framing")
  if cmpIgnoreCase(key, "Content-Length") == 0:
    if seenLength:
      raise newException(ValueError, "Duplicate response Content-Length")
    seenLength = true
    let length = parseResponseLength(value)
    if bodyLen >= 0 and length != bodyLen:
      raise newException(ValueError, "Response Content-Length mismatch")

proc validateRawHeaders*(headers: openArray[tuple[key, val: string]],
                         bodyLen = -1) =
  var seenLength = false
  for header in headers:
    validateHeaderPair(header.key, header.val)
    checkFraming(header.key, header.val, seenLength, bodyLen)

proc validateHttpHeaders*(headers: HttpHeaders, bodyLen = -1) =
  if headers.isNil:
    return
  var seenLength = false
  for key, value in headers:
    validateHeaderPair(key, value)
    checkFraming(key, value, seenLength, bodyLen)

# ------------------------------------------------------------------------------
# Content-Disposition uses a quoted-string: escape quotation and backslash.
# Invalid controls are rejected instead of being reflected into the response.
# ------------------------------------------------------------------------------
proc attachmentDisposition*(filename: string): string =
  result = "attachment"
  if filename.len == 0:
    return
  result.add("; filename=\"")
  for c in filename:
    if ord(c) < 32 or ord(c) == 127:
      raise newException(ValueError, "Invalid attachment filename")
    if c == '\"' or c == '\\':
      result.add('\\')
    result.add(c)
  result.add('\"')
