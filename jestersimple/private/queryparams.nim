# ------------------------------------------------------------------------------
# Form/query parameter decoding: one percent-decoding pass per component.
# ------------------------------------------------------------------------------
import std/strutils

# ------------------------------------------------------------------------------
# Convert one ASCII hexadecimal digit. -1 means invalid.
# ------------------------------------------------------------------------------
proc hexValue(c: char): int {.inline.} =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

# ------------------------------------------------------------------------------
# Reject malformed escapes and NUL before dispatching user-controlled data.
# An invalid input is never included in an exception or log message.
# ------------------------------------------------------------------------------
proc validUrlEncoded*(data: string): bool =
  var i = 0
  while i < data.len:
    if data[i] == '\0':
      return false
    if data[i] == '%':
      if i + 2 >= data.len:
        return false
      let hi = hexValue(data[i + 1])
      let lo = hexValue(data[i + 2])
      if hi < 0 or lo < 0 or (hi == 0 and lo == 0):
        return false
      i += 3
    else:
      inc i
  true

# ------------------------------------------------------------------------------
# Decode a component once. Only form/query data maps '+' to a space.
# ------------------------------------------------------------------------------
proc decodeComponent(data: string, first, last: int): string =
  result = newStringOfCap(last - first)
  var i = first
  while i < last:
    case data[i]
    of '+':
      result.add ' '
      inc i
    of '%':
      if i + 2 >= last:
        raise newException(ValueError, "Malformed URL-encoded parameter")
      let hi = hexValue(data[i + 1])
      let lo = hexValue(data[i + 2])
      if hi < 0 or lo < 0 or (hi == 0 and lo == 0):
        raise newException(ValueError, "Malformed URL-encoded parameter")
      result.add chr(hi * 16 + lo)
      i += 3
    of '\0':
      raise newException(ValueError, "Malformed URL-encoded parameter")
    else:
      result.add data[i]
      inc i

# ------------------------------------------------------------------------------
# Split only on literal '&' and the first literal '='. Encoded separators
# remain within their components. Ignore empty fields but keep empty keys.
# ------------------------------------------------------------------------------
iterator decodedFormPairs*(data: string): tuple[key, value: string] =
  var first = 0
  while first < data.len:
    var last = data.find('&', first)
    if last < 0:
      last = data.len

    if first < last:
      let eqPos = data.find('=', first)
      if eqPos >= 0 and eqPos < last:
        yield (decodeComponent(data, first, eqPos),
               decodeComponent(data, eqPos + 1, last))
      else:
        yield (decodeComponent(data, first, last), "")
    first = last + 1

# ------------------------------------------------------------------------------
# Check the media type exactly; optional parameters are allowed.
# ------------------------------------------------------------------------------
proc isUrlEncodedForm*(contentType: string): bool =
  let endPos = contentType.find(';')
  let mediaType = if endPos >= 0: contentType[0 ..< endPos] else: contentType
  mediaType.strip().toLowerAscii() == "application/x-www-form-urlencoded"
