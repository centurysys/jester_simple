# ------------------------------------------------------------------------------
# Bounded multipart/form-data parsing for already size-limited HTTP bodies.
# ------------------------------------------------------------------------------
import std/[strutils, strtabs, tables]

const
  MaxBoundaryLength = 70
  MaxParts = 128
  MaxPartHeaders = 64
  MaxPartHeaderBytes = 8192
  BadMultipart = "Malformed multipart/form-data"

type
  MultiData* = OrderedTable[string, tuple[fields: StringTableRef, body: string]]

# ------------------------------------------------------------------------------
# Validate MIME parameter/header token characters without locale dependencies.
# ------------------------------------------------------------------------------
proc isToken(c: char): bool {.inline.} =
  c in {'A'..'Z', 'a'..'z', '0'..'9', '!', '#', '$', '%', '&',
        '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~'}

proc skipOws(s: string, pos: var int) {.inline.} =
  while pos < s.len and s[pos] in {' ', '\t'}:
    inc pos

proc fail() {.noReturn.} =
  raise newException(ValueError, BadMultipart)

# ------------------------------------------------------------------------------
# Read a media type / disposition value with strictly parsed MIME parameters.
# Quotes and quoted-pair escaping are handled without splitting on semicolons.
# ------------------------------------------------------------------------------
proc parseParameters(s: string): tuple[
    main: string, attrs: Table[string, string]] =
  result.attrs = initTable[string, string]()
  let semi = s.find(';')
  let mainEnd = if semi < 0: s.len else: semi
  result.main = s[0 ..< mainEnd].strip().toLowerAscii()
  if result.main.len == 0:
    fail()
  var pos = mainEnd
  while pos < s.len:
    if s[pos] != ';':
      fail()
    inc pos
    skipOws(s, pos)
    let keyStart = pos
    while pos < s.len and isToken(s[pos]):
      inc pos
    if pos == keyStart:
      fail()
    let key = s[keyStart ..< pos].toLowerAscii()
    skipOws(s, pos)
    if pos >= s.len or s[pos] != '=':
      fail()
    inc pos
    skipOws(s, pos)
    var value = ""
    if pos < s.len and s[pos] == '"':
      inc pos
      var terminated = false
      while pos < s.len:
        let c = s[pos]
        if c == '"':
          inc pos
          terminated = true
          break
        if c == '\\':
          inc pos
          if pos >= s.len or ord(s[pos]) < 32 or ord(s[pos]) == 127:
            fail()
          value.add s[pos]
          inc pos
        else:
          if (ord(c) < 32 and c != '\t') or ord(c) == 127:
            fail()
          value.add c
          inc pos
      if not terminated:
        fail()
    else:
      let valueStart = pos
      while pos < s.len and isToken(s[pos]):
        inc pos
      if pos == valueStart:
        fail()
      value = s[valueStart ..< pos]
    skipOws(s, pos)
    if pos < s.len and s[pos] != ';':
      fail()
    if result.attrs.hasKey(key):
      fail()
    result.attrs[key] = value

# ------------------------------------------------------------------------------
# RFC 2046 boundary: at most 70 ASCII characters, nonempty and not ending in
# whitespace. The quoted form can contain internal spaces and MIME bchars.
# ------------------------------------------------------------------------------
proc validBoundary(boundary: string): bool =
  if boundary.len == 0 or boundary.len > MaxBoundaryLength or
      boundary[^1] == ' ':
    return false
  const extraChars = {'\'', '(', ')', '+', '_', ',', '-', '.', '/',
                      ':', '=', '?', ' '}
  for c in boundary:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9'} and c notin extraChars:
      return false
  true

proc isMultipartForm*(contentType: string): bool =
  let semi = contentType.find(';')
  let mainEnd = if semi < 0: contentType.len else: semi
  contentType[0 ..< mainEnd].strip().toLowerAscii() == "multipart/form-data"

# ------------------------------------------------------------------------------
# Find only complete MIME delimiter lines. An embedded boundary-like sequence
# with an invalid suffix is ordinary binary part data, not a delimiter.
# ------------------------------------------------------------------------------
proc boundaryAt(s: string, pos: int, delimiter: string,
                first: bool): bool =
  if pos < 0 or pos + delimiter.len > s.len:
    return false
  if not first and (pos < 2 or s[pos - 2] != '\r' or
                    s[pos - 1] != '\n'):
    return false
  let after = pos + delimiter.len
  if after + 1 >= s.len:
    return false
  if s[after] == '\r' and s[after + 1] == '\n':
    return true
  if s[after] == '-' and s[after + 1] == '-':
    let finalPos = after + 2
    return finalPos == s.len or
      (finalPos + 1 < s.len and s[finalPos] == '\r' and
       s[finalPos + 1] == '\n')
  false

proc nextDelimiter(s: string, delimiter: string, start: int,
                   first: bool): int =
  var pos = s.find(delimiter, start)
  while pos >= 0:
    if boundaryAt(s, pos, delimiter, first) and
        (pos == 0 or not first or
         (pos >= 2 and s[pos - 2] == '\r' and s[pos - 1] == '\n')):
      return pos
    pos = s.find(delimiter, pos + 1)
  -1

# ------------------------------------------------------------------------------
# Parse a part's bounded headers, including required form-data disposition.
# Values in the returned fields table are case-insensitive for compatibility.
# ------------------------------------------------------------------------------
proc readPartHeaders(body: string, pos: var int): tuple[
    fields: StringTableRef, name: string] =
  result.fields = newStringTable(modeCaseInsensitive)
  var total = 0
  var count = 0
  var hasDisposition = false
  while true:
    if pos >= body.len:
      fail()
    let lineEnd = body.find("\r\n", pos)
    if lineEnd < 0:
      fail()
    let lineLen = lineEnd - pos
    total += lineLen + 2
    if total > MaxPartHeaderBytes:
      fail()
    pos = lineEnd + 2
    if lineLen == 0:
      break
    inc count
    if count > MaxPartHeaders:
      fail()
    let lineStart = lineEnd - lineLen
    let colon = body.find(':', lineStart)
    if colon <= lineStart or colon >= lineEnd:
      fail()
    for i in lineStart ..< colon:
      if not isToken(body[i]):
        fail()
    let fieldName = body[lineStart ..< colon]
    let fieldKey = fieldName.toLowerAscii()
    let value = body[colon + 1 ..< lineEnd].strip(chars = {' ', '\t'})
    for c in value:
      if (ord(c) < 32 and c != '\t') or ord(c) == 127:
        fail()
    if result.fields.hasKey(fieldName):
      fail()
    result.fields[fieldName] = value
    if fieldKey == "content-disposition":
      let disposition = parseParameters(value)
      if disposition.main != "form-data" or
          not disposition.attrs.hasKey("name"):
        fail()
      result.name = disposition.attrs["name"]
      result.fields["name"] = result.name
      if disposition.attrs.hasKey("filename"):
        result.fields["filename"] = disposition.attrs["filename"]
      if disposition.attrs.hasKey("filename*"):
        result.fields["filename*"] = disposition.attrs["filename*"]
      hasDisposition = true
  if not hasDisposition:
    fail()

# ------------------------------------------------------------------------------
# Parse complete multipart body. No reads beyond the buffer, no byte-at-a-time
# copying, and a fixed cap on part/header counts in addition to maxBody.
# ------------------------------------------------------------------------------
proc parseMultiPart*(body: string, boundary: string): MultiData =
  result = initOrderedTable[string, tuple[fields: StringTableRef, body: string]]()
  if not validBoundary(boundary):
    fail()
  let delimiter = "--" & boundary
  let first = nextDelimiter(body, delimiter, 0, true)
  if first < 0:
    fail()
  var pos = first + delimiter.len
  if body[pos] == '-':
    # Empty multipart body with a closing delimiter.
    pos += 2
    if pos < body.len and
        not (pos + 1 < body.len and body[pos] == '\r' and
             body[pos + 1] == '\n'):
      fail()
    return
  if pos + 1 >= body.len or body[pos] != '\r' or body[pos + 1] != '\n':
    fail()
  pos += 2
  var parts = 0
  while true:
    inc parts
    if parts > MaxParts:
      fail()
    let part = readPartHeaders(body, pos)
    let next = nextDelimiter(body, delimiter, pos, false)
    if next < 0:
      fail()
    # The CRLF belongs to the boundary, not the file bytes.
    let contentEnd = next - 2
    if contentEnd < pos:
      fail()
    result[part.name] = (fields: part.fields, body: body[pos ..< contentEnd])
    pos = next + delimiter.len
    if body[pos] == '-':
      pos += 2
      if pos < body.len and
          not (pos + 1 < body.len and body[pos] == '\r' and
               body[pos + 1] == '\n'):
        fail()
      return
    if pos + 1 >= body.len or body[pos] != '\r' or body[pos + 1] != '\n':
      fail()
    pos += 2

proc parseMPFD*(contentType: string, body: string): MultiData =
  let media = parseParameters(contentType)
  if media.main != "multipart/form-data" or
      not media.attrs.hasKey("boundary"):
    fail()
  parseMultiPart(body, media.attrs["boundary"])
