# Copyright (C) 2012 Dominik Picheta
# MIT License - Look at license.txt for details.
import parseutils, strutils, tables, net, mimetypes, asyncdispatch
import ./[queryparams, multipart]
export multipart

type
  Settings* = ref object
    staticDir*: string # By default ./public
    appName*: string
    mimes*: MimeDb
    port*: Port
    bindAddr*: string
    reusePort*: bool
    maxBody*: int
    maxConnections*: int
    maxHeaderBytes*: int
    maxHeaderFields*: int
    headerTimeoutMs*: int
    bodyTimeoutMs*: int
    keepAliveTimeoutMs*: int
    managedSendTimeoutMs*: int
    responseStartTimeoutMs*: int
    streamTotalTimeoutMs*: int
    trustedProxies*: seq[string]
    allowedHosts*: seq[string]
    publicBaseUrl*: string
    futureErrorHandler*: proc (fut: Future[void]) {.closure, gcsafe.}

  JesterError* = object of CatchableError

# ------------------------------------------------------------------------------
# API: Make a per-server copy of mutable Settings before accepting requests.
# ------------------------------------------------------------------------------
proc snapshotSettings*(source: Settings): Settings =
  if source.isNil:
    raise newException(ValueError, "Server settings are nil")
  new(result)
  result[] = source[]
  # Nim seq assignment can share storage; copy the allowlists explicitly.
  result.trustedProxies = @[]
  for network in source.trustedProxies:
    result.trustedProxies.add(network)
  result.allowedHosts = @[]
  for host in source.allowedHosts:
    result.allowedHosts.add(host)

# ------------------------------------------------------------------------------
# API: Reject invalid resource limits instead of silently clamping at listen.
# ------------------------------------------------------------------------------
proc validateServerSettings*(settings: Settings) =
  if settings.isNil:
    raise newException(ValueError, "Server settings are nil")
  if settings.staticDir.len == 0:
    raise newException(ValueError, "Static dir cannot be empty")
  if settings.maxBody < 0 or settings.maxConnections < 1 or
      settings.maxHeaderBytes < 1 or settings.maxHeaderFields < 1 or
      settings.headerTimeoutMs < 1 or settings.bodyTimeoutMs < 1 or
      settings.keepAliveTimeoutMs < 1 or
      settings.managedSendTimeoutMs < 1 or
      settings.responseStartTimeoutMs < 1 or
      settings.streamTotalTimeoutMs < 1:
    raise newException(ValueError, "Invalid HTTP resource limits")

proc parseUrlQuery*(query: string, result: var Table[string, string])
    {.deprecated: "use request.params or decodedFormPairs".} =
  ## Historical helper retained for callers of private/utils.
  ## A leading question mark is accepted as before.
  let data = if query.startsWith("?"): query.substr(1) else: query
  for key, value in decodedFormPairs(data):
    result[key] = value

proc parseCookies*(s: string): Table[string, string] =
  ## parses cookies into a string table.
  ##
  ## The proc is meant to parse the Cookie header set by a client, not the
  ## "Set-Cookie" header set by servers.

  result = initTable[string, string]()
  var i = 0
  while true:
    i += skipWhile(s, {' ', '\t'}, i)
    var keystart = i
    i += skipUntil(s, {'='}, i)
    var keyend = i-1
    if i >= len(s): break
    inc(i) # skip '='
    var valstart = i
    i += skipUntil(s, {';'}, i)
    result[substr(s, keystart, keyend)] = substr(s, valstart, i-1)
    if i >= len(s): break
    inc(i) # skip ';'

type
  SameSite* = enum
    None, Lax, Strict

# ------------------------------------------------------------------------------
# Reject delimiter injection as well as CR/LF in structured cookie components.
# Cookie value is serialized without quoting, so use the cookie-octet subset.
# ------------------------------------------------------------------------------
proc validateCookieName*(name: string) =
  if name.len == 0:
    raise newException(ValueError, "Invalid cookie name")
  const separators = {'(', ')', '<', '>', '@', ',', ';', ':', '\\',
                      '\"', '/', '[', ']', '?', '=', '{', '}', ' ', '\t'}
  for c in name:
    if ord(c) < 33 or ord(c) > 126 or c in separators:
      raise newException(ValueError, "Invalid cookie name")

proc validateCookieValue*(value: string) =
  for c in value:
    if ord(c) < 33 or ord(c) > 126 or
        c in {',', ';', '\\', '\"'}:
      raise newException(ValueError, "Invalid cookie value")

proc validateCookieAttribute*(value: string) =
  for c in value:
    if ord(c) < 32 or ord(c) > 126 or c in {';', '\\', '\"'}:
      raise newException(ValueError, "Invalid cookie attribute")

proc validateCookieDomain*(domain: string) =
  for c in domain:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '-'}:
      raise newException(ValueError, "Invalid cookie domain")

proc makeCookie*(key, value, expires: string, domain = "", path = "",
                 secure = false, httpOnly = false,
                 sameSite = Lax): string =
  validateCookieName(key)
  validateCookieValue(value)
  validateCookieAttribute(expires)
  validateCookieDomain(domain)
  validateCookieAttribute(path)
  result = ""
  result.add key & "=" & value
  if domain != "": result.add("; Domain=" & domain)
  if path != "": result.add("; Path=" & path)
  if expires != "": result.add("; Expires=" & expires)
  if secure: result.add("; Secure")
  if httpOnly: result.add("; HttpOnly")
  result.add("; SameSite=" & $sameSite)
