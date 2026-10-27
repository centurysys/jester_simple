import uri, tables, strutils, strtabs, re, options

import private/utils

import private/httptransport
import private/trustboundary
import private/queryparams

type
  NativeRequest* = httptransport.Request

type
  Request* = object
    req: NativeRequest
    patternParams: Option[Table[string, string]]
    reMatches: array[MaxSubpatterns, string]
    settings*: Settings
    origin: RequestOrigin
    multipartData: ref MultiData

proc body*(req: Request): string =
  ## Body of the request, only for POST.
  ##
  ## You're probably looking for ``formData``
  ## instead.
  req.req.body

proc headers*(req: Request): HttpHeaders =
  ## Headers received with the request.
  ## Retrieving these is case insensitive.
  req.req.headers

proc path*(req: Request): string =
  ## Path of request without the query string.
  let u = req.req.url
  return u.path

proc query*(req: Request): string =
  ## Query string of request
  let u = req.req.url
  return u.query

proc reqMethod*(req: Request): HttpMethod =
  ## Request method, eg. HttpGet, HttpPost
  req.req.reqMethod

proc reqMeth*(req: Request): HttpMethod {.deprecated.} =
  req.reqMethod

proc ip*(req: Request): string =
  ## Client IP from the socket, or from a chain of explicitly trusted proxies.
  req.origin.ip

# ------------------------------------------------------------------------------
# Validate query and form encoding before route dispatch. This avoids turning
# malformed client input into an application exception (HTTP 500).
# ------------------------------------------------------------------------------
proc validParameterEncoding*(req: var Request): bool =
  if not validUrlEncoded(req.query):
    return false
  let contentType: string = req.headers.getOrDefault("Content-Type")
  if isUrlEncodedForm(contentType):
    return validUrlEncoded(req.body)
  if isMultipartForm(contentType):
    try:
      new(req.multipartData)
      req.multipartData[] = parseMPFD(contentType, req.body)
    except ValueError:
      req.multipartData = nil
      return false
  true

# ------------------------------------------------------------------------------
# Merge encoded fields into the last-value-wins parameter representation.
# ------------------------------------------------------------------------------
proc appendDecoded(params: var Table[string, string], encoded: string) =
  for key, value in decodedFormPairs(encoded):
    params[key] = value

# ------------------------------------------------------------------------------
# Merge encoded fields into the ordered-per-key multi-value representation.
# ------------------------------------------------------------------------------
proc appendDecoded(params: var Table[string, seq[string]], encoded: string) =
  for key, value in decodedFormPairs(encoded):
    if params.hasKey(key):
      params[key].add value
    else:
      params[key] = @[value]

proc params*(req: Request): Table[string, string] =
  ## Pattern parameters are raw, percent-encoded path substrings.
  ## Query and urlencoded-form components are decoded exactly once.
  ## Later query/form fields replace earlier values with the same key.
  if req.patternParams.isSome():
    result = req.patternParams.get()
  else:
    result = initTable[string, string]()

  appendDecoded(result, req.query)
  let contentType: string = req.headers.getOrDefault("Content-Type")
  if isUrlEncodedForm(contentType):
    appendDecoded(result, req.body)

proc paramValuesAsSeq*(req: Request): Table[string, seq[string]] =
  ## Keep duplicates in query-then-form order after any raw pattern value.
  ## Keys/values are decoded once, with no decoding of pattern captures.
  result = initTable[string, seq[string]]()
  if req.patternParams.isSome():
    for key, value in req.patternParams.get().pairs:
      result[key] = @[value]

  appendDecoded(result, req.query)
  let contentType: string = req.headers.getOrDefault("Content-Type")
  if isUrlEncodedForm(contentType):
    appendDecoded(result, req.body)

proc formData*(req: Request): MultiData =
  ## Already validated and parsed before dispatch; repeated access is cheap.
  ## Keep a direct parse fallback for standalone Request use.
  if not req.multipartData.isNil:
    return req.multipartData[]
  let contentType: string = req.headers.getOrDefault("Content-Type")
  if isMultipartForm(contentType):
    return parseMPFD(contentType, req.body)
  result = initOrderedTable[string, tuple[fields: StringTableRef, body: string]]()

proc matches*(req: Request): array[MaxSubpatterns, string] =
  req.reMatches

proc secure*(req: Request): bool =
  ## Whether the external scheme is HTTPS (trusted proxy or public base URL).
  req.origin.secure

proc port*(req: Request): int =
  ## External port, never taken from an untrusted SERVER_PORT header.
  req.origin.port

proc host*(req: Request): string =
  ## Host approved for absolute URL generation, or empty if untrusted.
  req.origin.host

proc appName*(req: Request): string =
  ## This is set by the user in ``run``, it is
  ## overriden by the "SCRIPT_NAME" scgi
  ## parameter.
  req.settings.appName

# ------------------------------------------------------------------------------
# Strip a complete mount prefix, not a partial path segment such as /foobar.
# Do not include user-provided paths in exception messages.
# ------------------------------------------------------------------------------
proc stripAppName(path, appName: string): string =
  if path.len == 0:
    raise newException(ValueError, "Empty HTTP request path")

  if appName.len == 0:
    return path

  var prefix = appName
  if prefix[0] != '/':
    prefix = "/" & prefix
  while prefix.len > 1 and prefix[^1] == '/':
    prefix.setLen(prefix.len - 1)

  if prefix == "/":
    return path
  if path == prefix:
    return "/"
  if path.len > prefix.len and path.startsWith(prefix) and
      path[prefix.len] == '/':
    return path[prefix.len .. ^1]

  raise newException(ValueError, "Request path is outside application prefix")

proc pathInfo*(req: Request): string =
  ## This is ``.path`` without ``.appName``.
  req.path.stripAppName(req.appName)

# TODO: Can cookie keys be duplicated?
proc cookies*(req: Request): Table[string, string] =
  ## Cookies from the browser.
  if (let cookie = req.headers.getOrDefault("Cookie"); cookie != ""):
    result = parseCookies(cookie)
  else:
    result = initTable[string, string]()

#[ Protected procs ]#

proc initRequest*(req: NativeRequest, settings: Settings): Request {.inline.} =
  Request(
    req: req,
    settings: settings,
    origin: resolveOrigin(req.hostname, req.headers, settings)
  )

proc getNativeReq*(req: Request): NativeRequest =
  req.req

#[ Only to be used by our route macro. ]#
proc setPatternParams*(req: var Request, p: Table[string, string]) =
  req.patternParams = some(p)

proc setReMatches*(req: var Request, r: array[MaxSubpatterns, string]) =
  req.reMatches = r
