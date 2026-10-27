# Based on Nim 2.2.12 lib/pure/asynchttpserver.nim.
# Copyright (c) 2015 Dominik Picheta. MIT License; see license.txt.
# Jester Simple modifications (2026): strict HTTP/1.1 body framing and body limits.
# Keep this module local until upstream provides equivalent framing guarantees.

import std/[asyncnet, asyncdispatch, parseutils, uri, strutils, monotimes]
import std/httpcore
from std/nativesockets import getLocalAddr, AF_INET
import ./[responsevalidation, trustboundary]

export httpcore except parseHeader

const
  MaxLine = 8 * 1024
  BodyReadBlock = 16 * 1024
  MaxTrailerBytes = 8 * 1024
  WatchdogTickMs = 250
  # Legacy synchronous writes cannot await backpressure. Bound queued data
  # and Future nodes per connection; streaming callers should use sendAsync.
  MaxQueuedRawBytes* = 256 * 1024
  MaxQueuedRawWrites* = 64
  RawSendTimeoutMs = 15_000

# ------------------------------------------------------------------------------
# Public transport types match Nim 2.2.12 asynchttpserver.
# ------------------------------------------------------------------------------
type
  Request* = object
    client*: AsyncSocket
    reqMethod*: HttpMethod
    headers*: HttpHeaders
    protocol*: tuple[orig: string, major, minor: int]
    url*: Uri
    hostname*: string
    body*: string
    rawWrites: RawWriteState

  AsyncHttpServer* = ref object
    socket: AsyncSocket
    reuseAddr: bool
    reusePort: bool
    maxBody: int
    maxFDs: int
    maxConnections: int
    activeConnections: int
    maxHeaderBytes: int
    maxHeaderFields: int
    headerTimeoutMs: int
    bodyTimeoutMs: int
    keepAliveTimeoutMs: int

  ConnectionWatch = ref object
    client: AsyncSocket
    active: bool
    deadlineTicks: int64

  # The request is copied between transport and router layers. Keep the
  # response state in a ref so every copy sees the same irreversible transition.
  OutputMode = enum
    omIdle, omManaged, omRaw, omUpgraded

  # Raw writers must finish before processRequest can close the connection.
  RawWriteState = ref object
    mode: OutputMode
    client: AsyncSocket
    pending: Future[void]
    failed: bool
    started: bool
    queuedBytes: int
    queuedWrites: int

# ------------------------------------------------------------------------------
# API: Return the bound port (including an automatically assigned port).
# ------------------------------------------------------------------------------
proc getPort*(server: AsyncHttpServer): Port =
  getLocalAddr(server.socket)[1]

# ------------------------------------------------------------------------------
# API: Create a server with an enforced maximum request body length.
# ------------------------------------------------------------------------------
proc newAsyncHttpServer*(reuseAddr = true, reusePort = false,
                         maxBody = 8388608, maxConnections = 64,
                         maxHeaderBytes = 16384, maxHeaderFields = 100,
                         headerTimeoutMs = 5000, bodyTimeoutMs = 15000,
                         keepAliveTimeoutMs = 5000): AsyncHttpServer =
  AsyncHttpServer(
    reuseAddr: reuseAddr, reusePort: reusePort,
    maxBody: max(0, maxBody),
    maxConnections: max(1, maxConnections),
    maxHeaderBytes: max(1, maxHeaderBytes),
    maxHeaderFields: max(1, maxHeaderFields),
    headerTimeoutMs: max(1, headerTimeoutMs),
    bodyTimeoutMs: max(1, bodyTimeoutMs),
    keepAliveTimeoutMs: max(1, keepAliveTimeoutMs)
  )

# ------------------------------------------------------------------------------
# The watchdog runs once per connection, not once per recv or HTTP header.
# Expiration closes the socket; pending async reads then unwind normally.
# ------------------------------------------------------------------------------
proc setDeadline(watch: ConnectionWatch, timeoutMs: int) {.inline.} =
  watch.deadlineTicks = getMonoTime().ticks + int64(timeoutMs) * 1_000_000

proc monitorDeadline(watch: ConnectionWatch) {.async.} =
  while watch.active:
    if getMonoTime().ticks >= watch.deadlineTicks:
      watch.active = false
      if not watch.client.isClosed:
        watch.client.close()
      return
    await sleepAsync(WatchdogTickMs)


# ------------------------------------------------------------------------------
# Raw writes are ordered and connection-owned. The synchronous compatibility
# API cannot block for backpressure, so it has a strict queue limit. Callers
# streaming larger responses must await sendAsync in their route.
# ------------------------------------------------------------------------------
proc writeRawOrdered(state: RawWriteState, previous: Future[void],
                     payload: string) {.async.} =
  try:
    if previous != nil:
      await previous
    if state.failed or state.client.isClosed:
      state.failed = true
      return
    let sending = state.client.send(payload)
    if not (await withTimeout(sending, RawSendTimeoutMs)):
      state.failed = true
      if not state.client.isClosed:
        state.client.close()
      # Closing an AsyncSocket does not guarantee its already-pending send
      # Future completes. Never await it indefinitely after a timeout.
      # No asyncCheck was installed, so a late socket error is contained.
      if sending.finished:
        await sending
      return
    await sending
  except CatchableError:
    state.failed = true
    if not state.client.isClosed:
      state.client.close()
  finally:
    dec state.queuedWrites
    state.queuedBytes -= payload.len

proc enqueueRawWrite(state: RawWriteState, payload: string): Future[void] =
  if state.mode notin {omIdle, omRaw}:
    raise newException(ValueError, "HTTP output already started or upgraded")
  if state.failed or state.client.isClosed:
    raise newException(IOError, "Raw response connection is closed")
  if payload.len > MaxQueuedRawBytes - state.queuedBytes or
      state.queuedWrites >= MaxQueuedRawWrites:
    raise newException(ValueError, "Raw response queue limit exceeded; use sendAsync")
  let previous = state.pending
  state.mode = omRaw
  state.started = true
  inc state.queuedWrites
  state.queuedBytes += payload.len
  result = writeRawOrdered(state, previous, payload)
  state.pending = result

proc queueRawWrite*(req: Request, payload: string) =
  if req.rawWrites.isNil:
    raise newException(ValueError, "Raw write state is not initialized")
  if req.rawWrites.mode notin {omIdle, omRaw}:
    raise newException(ValueError, "Raw writes are forbidden after HTTP response or Upgrade")
  if payload.len > 0:
    discard enqueueRawWrite(req.rawWrites, payload)

proc sendRawAsync*(req: Request, payload: string) {.async.} =
  ## A bounded, awaitable raw write. Await each call for backpressure.
  ## Large payloads are split into bounded chunks without creating an
  ## unbounded chain of Futures or per-write task objects.
  if req.rawWrites.isNil:
    raise newException(ValueError, "Raw write state is not initialized")
  if req.rawWrites.mode notin {omIdle, omRaw}:
    raise newException(ValueError, "Raw writes are forbidden after HTTP response or Upgrade")
  var offset = 0
  while offset < payload.len:
    let count = min(MaxQueuedRawBytes, payload.len - offset)
    let state = req.rawWrites
    while state.queuedWrites >= MaxQueuedRawWrites or
        count > MaxQueuedRawBytes - state.queuedBytes:
      if state.pending.isNil:
        raise newException(IOError, "Raw response queue is unavailable")
      await state.pending
      if state.failed:
        raise newException(IOError, "Raw response send failed")
    let pending = enqueueRawWrite(state, payload[offset ..< offset + count])
    await pending
    if state.failed:
      raise newException(IOError, "Raw response send failed")
    offset += count

# ------------------------------------------------------------------------------
# API: Report whether the connection has begun any HTTP response or Upgrade.
# This is shared across NativeRequest copies; it does not inspect socket bytes.
# ------------------------------------------------------------------------------
proc responseStarted*(req: Request): bool {.inline.} =
  not req.rawWrites.isNil and req.rawWrites.mode != omIdle

proc rawOutputStarted*(req: Request): bool {.inline.} =
  not req.rawWrites.isNil and req.rawWrites.mode == omRaw

proc upgradeStarted*(req: Request): bool {.inline.} =
  not req.rawWrites.isNil and req.rawWrites.mode == omUpgraded

# ------------------------------------------------------------------------------
# API: Reserve the connection for a protocol upgrade before writing HTTP 101.
# The caller validates the handshake first and awaits the upgraded session
# within the route Future. The HTTP transport retains ownership of the socket.
# An unsuccessful handshake after reservation must close, not send HTTP 4xx.
# ------------------------------------------------------------------------------
proc beginUpgrade*(req: Request): AsyncSocket =
  if req.rawWrites.isNil or req.client.isNil or req.client.isClosed:
    raise newException(IOError, "Upgrade connection is unavailable")
  if req.rawWrites.mode != omIdle or req.rawWrites.failed:
    raise newException(ValueError, "HTTP response already started or upgraded")
  req.rawWrites.mode = omUpgraded
  return req.client

# ------------------------------------------------------------------------------
# Reserve the normal HTTP output path before scheduling its first socket send.
# Validation must happen before this transition to permit a fixed 500 fallback.
# ------------------------------------------------------------------------------
proc beginManagedResponse(req: Request) =
  if req.rawWrites.isNil or req.client.isNil or req.client.isClosed:
    raise newException(IOError, "HTTP response connection is unavailable")
  if req.rawWrites.mode != omIdle or req.rawWrites.failed:
    raise newException(ValueError, "HTTP output already started or upgraded")
  req.rawWrites.mode = omManaged

proc abortRawWrites*(req: Request) =
  if not req.rawWrites.isNil:
    req.rawWrites.failed = true
    if not req.client.isClosed:
      req.client.close()

proc drainRawWrites(req: Request): Future[bool] {.async.} =
  if req.rawWrites.isNil:
    return true
  if req.rawWrites.pending != nil:
    await req.rawWrites.pending
  return not req.rawWrites.failed

# ------------------------------------------------------------------------------
# API: Write response headers using the upstream transport format.
# ------------------------------------------------------------------------------
proc addHeaders(msg: var string, headers: HttpHeaders) =
  for key, val in headers:
    msg.add(key & ": " & val & "\c\L")

proc sendHeaders*(req: Request, headers: HttpHeaders): Future[void] =
  validateHttpHeaders(headers)
  req.beginManagedResponse()
  var msg = ""
  msg.addHeaders(headers)
  return req.client.send(msg)

# ------------------------------------------------------------------------------
# Send a header-only prefix for a file streamed in subsequent writes.
# Actual byte count is owned by the streaming caller (Step 14 will unify it).
# ------------------------------------------------------------------------------
proc respondHeaders*(req: Request, code: HttpCode,
                     headers: HttpHeaders,
                     firstBodyChunk = ""): Future[void] =
  # For a streamed response, include its first body chunk in the same socket
  # write as the headers. A tiny separate write can otherwise stall behind
  # Nagle/delayed-ACK interaction for tens of milliseconds on keep-alive TCP.
  # Content-Length describes the complete file, not only firstBodyChunk.
  validateHttpHeaders(headers)
  req.beginManagedResponse()
  var msg = "HTTP/1.1 " & $code & "\c\L"
  if headers != nil:
    msg.addHeaders(headers)
  msg.add("\c\L")
  msg.add(firstBodyChunk)
  return req.client.send(msg)

proc respond*(req: Request, code: HttpCode, content: string,
              headers: HttpHeaders = nil): Future[void] =
  validateHttpHeaders(headers, content.len)
  req.beginManagedResponse()
  var msg = "HTTP/1.1 " & $code & "\c\L"
  if headers != nil:
    msg.addHeaders(headers)
  if headers.isNil() or not headers.hasKey("Content-Length"):
    msg.add("Content-Length: ")
    msg.addInt(content.len)
    msg.add("\c\L")
  msg.add("\c\L")
  # HEAD carries the metadata of the equivalent GET response, including its
  # Content-Length, but no message body. This also applies to error pages.
  if req.reqMethod != HttpHead:
    msg.add(content)
  return req.client.send(msg)

# ------------------------------------------------------------------------------
# API: Parse HTTP protocol tokens as done by the upstream server.
# ------------------------------------------------------------------------------
proc parseProtocol(protocol: string): tuple[orig: string, major, minor: int] =
  var i = protocol.skipIgnoreCase("HTTP/")
  if i != 5:
    raise newException(ValueError, "Invalid request protocol")
  result.orig = protocol
  i.inc protocol.parseSaturatedNatural(result.major, i)
  if i < protocol.len:
    inc i
  i.inc protocol.parseSaturatedNatural(result.minor, i)

# ------------------------------------------------------------------------------
# API: Reject malformed framing and always close the connection.
# ------------------------------------------------------------------------------
proc rejectRequest(req: Request, code: HttpCode): Future[bool] {.async.} =
  try:
    await req.respond(code, $code, newHttpHeaders([("Connection", "close")]))
  except CatchableError:
    discard # The peer may already have closed its sending side.
  req.client.close()
  return false

# ------------------------------------------------------------------------------
# API: Validate a header field name before considering framing fields.
# ------------------------------------------------------------------------------
proc validFieldName(name: string): bool =
  if name.len == 0:
    return false
  const extra = "!#$%&'*+-.^_`|~"
  for c in name:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9'} and c notin extra:
      return false
  return true

# ------------------------------------------------------------------------------
# API: Decode a complete unsigned decimal Content-Length without overflow.
# ------------------------------------------------------------------------------
proc parseBodyLength(value: string, length: var int): bool =
  let field = value.strip()
  if field.len == 0:
    return false
  var n = 0
  for c in field:
    if c < '0' or c > '9':
      return false
    let digit = ord(c) - ord('0')
    if n > (high(int) - digit) div 10:
      return false
    n = n * 10 + digit
  length = n
  return true

# ------------------------------------------------------------------------------
# API: Decode a canonical hexadecimal chunk size (extensions unsupported).
# ------------------------------------------------------------------------------
proc parseChunkLength(line: string, length: var int): bool =
  # recvLineInto removes CRLF from non-empty lines.
  if line.len == 0:
    return false
  var n = 0
  for c in line:
    var digit = -1
    if c in {'0'..'9'}:
      digit = ord(c) - ord('0')
    elif c in {'a'..'f'}:
      digit = ord(c) - ord('a') + 10
    elif c in {'A'..'F'}:
      digit = ord(c) - ord('A') + 10
    if digit < 0 or n > (high(int) - digit) div 16:
      return false
    n = n * 16 + digit
  length = n
  return true

# ------------------------------------------------------------------------------
# API: Read exactly n bytes or return a shorter value on disconnect.
# ------------------------------------------------------------------------------
proc recvExact(client: AsyncSocket, n: int): Future[string] {.async.} =
  result = newStringOfCap(n)
  while result.len < n:
    let data = await client.recv(min(BodyReadBlock, n - result.len))
    if data.len == 0:
      return
    result.add(data)

# ------------------------------------------------------------------------------
# API: Read chunked data, enforcing the cumulative configured body limit.
# ------------------------------------------------------------------------------
proc recvChunked(client: AsyncSocket, lineFut: FutureVar[string],
                 maxBody: int): Future[tuple[code: HttpCode, body: string]] {.async.} =
  var body = ""
  while true:
    lineFut.mget().setLen(0)
    lineFut.clean()
    await client.recvLineInto(lineFut, maxLength = MaxLine)
    if lineFut.mget().len > MaxLine:
      return (Http400, "")
    var chunkSize: int
    if not parseChunkLength(lineFut.mget(), chunkSize):
      return (Http400, "")
    if chunkSize == 0:
      # Consume trailer fields and the terminating CRLF. Do not interpret
      # subsequent pipelined requests as trailer data.
      var trailerBytes = 0
      while true:
        lineFut.mget().setLen(0)
        lineFut.clean()
        await client.recvLineInto(lineFut, maxLength = MaxLine)
        let line = lineFut.mget()
        if line == "\c\L":
          return (Http200, body)
        # recvLineInto returns trailer field lines without CRLF.
        if line.find(':') <= 0:
          return (Http400, "")
        if line.len > MaxTrailerBytes - trailerBytes:
          return (Http400, "")
        trailerBytes += line.len
    # Subtraction instead of addition avoids overflow with attacker input.
    if chunkSize > maxBody - body.len:
      return (Http413, "")
    let chunk = await client.recvExact(chunkSize)
    if chunk.len != chunkSize:
      return (Http400, "")
    body.add(chunk)
    let terminator = await client.recvExact(2)
    if terminator != "\c\L":
      return (Http400, "")

# ------------------------------------------------------------------------------
# API: Process one request with unambiguous body framing.
# ------------------------------------------------------------------------------
proc processRequest(
    server: AsyncHttpServer, req: FutureVar[Request],
    client: AsyncSocket, address: sink string,
    lineFut: FutureVar[string], watch: ConnectionWatch,
    callback: proc (request: Request): Future[void] {.closure, gcsafe.}
): Future[bool] {.async.} =
  template request(): Request =
    req.mget()

  request.headers.clear()
  request.body = ""
  when defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc):
    request.hostname = address
  else:
    request.hostname.shallowCopy(address)
  request.client = client
  request.rawWrites = RawWriteState(client: client)

  # Include request line and blank lines in the aggregate header budget.
  var headerBytes = 0
  var fieldCount = 0

  # Request line: retain the small upstream HTTP parsing structure.
  for _ in 0..1:
    lineFut.mget().setLen(0)
    lineFut.clean()
    await client.recvLineInto(lineFut, maxLength = MaxLine) # Watched by connection deadline.
    if lineFut.mget() == "":
      client.close()
      return false
    let lineBytes = (if lineFut.mget() == "\c\L": 2
                     else: lineFut.mget().len + 2)
    if lineBytes > server.maxHeaderBytes - headerBytes:
      return await rejectRequest(request, Http431)
    headerBytes += lineBytes
    if lineFut.mget().len > MaxLine:
      return await rejectRequest(request, Http431)
    if lineFut.mget() != "\c\L":
      break

  var i = 0
  for linePart in lineFut.mget().split(' '):
    case i
    of 0:
      case linePart
      of "GET": request.reqMethod = HttpGet
      of "POST": request.reqMethod = HttpPost
      of "HEAD": request.reqMethod = HttpHead
      of "PUT": request.reqMethod = HttpPut
      of "DELETE": request.reqMethod = HttpDelete
      of "PATCH": request.reqMethod = HttpPatch
      of "OPTIONS": request.reqMethod = HttpOptions
      of "CONNECT": request.reqMethod = HttpConnect
      of "TRACE": request.reqMethod = HttpTrace
      else: return await rejectRequest(request, Http400)
    of 1:
      try:
        parseUri(linePart, request.url)
      except ValueError:
        return await rejectRequest(request, Http400)
    of 2:
      try:
        request.protocol = parseProtocol(linePart)
      except ValueError:
        return await rejectRequest(request, Http400)
    else:
      return await rejectRequest(request, Http400)
    inc i
  if i != 3:
    return await rejectRequest(request, Http400)

  var hasContentLength = false
  var hasTransferEncoding = false
  var hasHost = false
  var forwardingFields: seq[string] = @[]
  # Reject framing duplicates before collapsing headers into HttpHeaders.
  while true:
    lineFut.mget().setLen(0)
    lineFut.clean()
    await client.recvLineInto(lineFut, maxLength = MaxLine) # Watched by connection deadline.
    if lineFut.mget() == "":
      client.close()
      return false
    let lineBytes = (if lineFut.mget() == "\c\L": 2
                     else: lineFut.mget().len + 2)
    if lineBytes > server.maxHeaderBytes - headerBytes:
      return await rejectRequest(request, Http431)
    headerBytes += lineBytes
    if lineFut.mget().len > MaxLine:
      return await rejectRequest(request, Http431)
    if lineFut.mget() == "\c\L":
      break
    inc fieldCount
    if fieldCount > server.maxHeaderFields:
      return await rejectRequest(request, Http431)
    # Parse the raw field line rather than using httpcore.parseHeader(),
    # which returns seq[string] and splits comma-separated values.
    # Framing fields must be validated as a single, unmodified field value.
    # recvLineInto returns non-empty header lines without CRLF.
    let headerLine = lineFut.mget()
    let colon = headerLine.find(':')
    if colon <= 0:
      return await rejectRequest(request, Http400)
    let key = headerLine[0 ..< colon]
    if not validFieldName(key):
      return await rejectRequest(request, Http400)
    let value = headerLine.substr(colon + 1).strip(chars = {' ', '\t'})
    for c in value:
      if (ord(c) < 32 and c != '\t') or ord(c) == 127:
        return await rejectRequest(request, Http400)
    if cmpIgnoreCase(key, "Content-Length") == 0:
      if hasContentLength:
        return await rejectRequest(request, Http400)
      hasContentLength = true
    elif cmpIgnoreCase(key, "Transfer-Encoding") == 0:
      if hasTransferEncoding:
        return await rejectRequest(request, Http400)
      hasTransferEncoding = true
    elif cmpIgnoreCase(key, "Host") == 0:
      if hasHost or not parseAuthority(value).valid:
        return await rejectRequest(request, Http400)
      hasHost = true
    elif key.toLowerAscii() in ["forwarded", "x-forwarded-for",
                                 "x-forwarded-host", "x-forwarded-proto"]:
      let lowerKey = key.toLowerAscii()
      if lowerKey in forwardingFields:
        return await rejectRequest(request, Http400)
      forwardingFields.add(lowerKey)
    request.headers[key] = value
    if request.headers.len > headerLimit:
      return await rejectRequest(request, Http400)

  if request.protocol == HttpVer11 and not hasHost:
    return await rejectRequest(request, Http400)

  if hasContentLength and hasTransferEncoding:
    return await rejectRequest(request, Http400)

  var contentLength = 0
  if hasContentLength:
    if not parseBodyLength(request.headers["Content-Length"], contentLength):
      return await rejectRequest(request, Http400)
    if contentLength > server.maxBody:
      return await rejectRequest(request, Http413)
  elif hasTransferEncoding:
    # No decoding stack is supported: require one, final 'chunked' coding.
    if cmpIgnoreCase(request.headers["Transfer-Encoding"].strip(), "chunked") != 0:
      return await rejectRequest(request, Http400)

  # A fixed, whole-body deadline prevents an arbitrarily slow sender
  # from keeping the connection alive by sending one byte at a time.
  # Arm this before sending 100 Continue.
  watch.setDeadline(server.bodyTimeoutMs)

  # Do not issue an interim response before validating the request framing.
  if request.reqMethod == HttpPost and request.headers.hasKey("Expect"):
    if cmpIgnoreCase(request.headers["Expect"].strip(), "100-continue") == 0:
      await client.send("HTTP/1.1 100 Continue\c\L\c\L")
    else:
      return await rejectRequest(request, Http417)

  if hasContentLength:
    request.body = await client.recvExact(contentLength)
    if request.body.len != contentLength:
      return await rejectRequest(request, Http400)
  elif hasTransferEncoding:
    let decoded = await recvChunked(client, lineFut, server.maxBody)
    if decoded.code != Http200:
      return await rejectRequest(request, decoded.code)
    request.body = decoded.body
  elif request.reqMethod == HttpPost:
    return await rejectRequest(request, Http411)

  # The receive timeout does not cover application processing or output.
  # Those paths are treated separately in later steps.
  watch.deadlineTicks = high(int64)
  await callback(request)
  # Even when the peer sent Connection: close, complete the queued raw
  # response before the transport tears down this socket.
  if not (await drainRawWrites(request)):
    request.client.close()
    return false

  # No further HTTP parser iteration after an explicit protocol upgrade.
  # Closing the socket remains processClient's responsibility.
  if request.upgradeStarted:
    return false

  if "upgrade" in request.headers.getOrDefault("connection"):
    return false
  if (request.protocol == HttpVer11 and
      cmpIgnoreCase(request.headers.getOrDefault("connection"), "close") != 0) or
     (request.protocol == HttpVer10 and
      cmpIgnoreCase(request.headers.getOrDefault("connection"), "keep-alive") == 0):
    return true
  request.client.close()
  return false

# ------------------------------------------------------------------------------
# API: Process all requests on a client socket until the connection closes.
# ------------------------------------------------------------------------------
proc processClient(
    server: AsyncHttpServer, client: AsyncSocket, address: string,
    callback: proc (request: Request): Future[void] {.closure, gcsafe.}
) {.async.} =
  var watch = ConnectionWatch(client: client, active: true)
  watch.setDeadline(server.headerTimeoutMs)
  asyncCheck monitorDeadline(watch)
  var req = newFutureVar[Request]("httptransport.processClient")
  req.mget().url = initUri()
  req.mget().headers = newHttpHeaders()
  var lineFut = newFutureVar[string]("httptransport.processClient")
  lineFut.mget() = newStringOfCap(80)
  try:
    var firstRequest = true
    while not client.isClosed:
      if not firstRequest:
        # This budget covers the entire next header read, including idle
        # keep-alive time, and is not refreshed by slow partial headers.
        watch.setDeadline(server.keepAliveTimeoutMs)
      firstRequest = false
      let retry = await processRequest(server, req, client, address,
                                       lineFut, watch, callback)
      if not retry:
        break
  except CatchableError:
    # Socket close on timeout/disconnect wakes the pending read. Do not let
    # a peer-triggered read exception fail an unchecked connection future.
    discard
  finally:
    watch.active = false
    if not client.isClosed:
      client.close()
    dec server.activeConnections

const nimMaxDescriptorsFallback* {.intdefine.} = 16_000

# ------------------------------------------------------------------------------
# API: Start listening with the upstream socket options.
# ------------------------------------------------------------------------------
proc listen*(server: AsyncHttpServer, port: Port, address = "",
             domain = AF_INET) =
  when declared(maxDescriptors):
    server.maxFDs = try: maxDescriptors() except: nimMaxDescriptorsFallback
  else:
    server.maxFDs = nimMaxDescriptorsFallback
  server.socket = newAsyncSocket(domain)
  if server.reuseAddr:
    server.socket.setSockOpt(OptReuseAddr, true)
  when not defined(nuttx):
    if server.reusePort:
      server.socket.setSockOpt(OptReusePort, true)
  server.socket.bindAddr(port, address)
  server.socket.listen()

proc shouldAcceptRequest*(server: AsyncHttpServer,
                          assumedDescriptorsPerRequest = 5): bool {.inline.} =
  result = assumedDescriptorsPerRequest < 0 or
    (activeDescriptors() + assumedDescriptorsPerRequest < server.maxFDs)

proc dispatchClient(
    server: AsyncHttpServer, client: AsyncSocket, address: string,
    callback: proc (request: Request): Future[void] {.closure, gcsafe.}
) =
  if server.activeConnections >= server.maxConnections or
      not shouldAcceptRequest(server):
    # Do not allocate another request parser or send a response to an
    # unknown/incomplete request. Drop excess connections immediately.
    client.close()
    return
  inc server.activeConnections
  asyncCheck processClient(server, client, address, callback)

proc acceptRequest*(
    server: AsyncHttpServer,
    callback: proc (request: Request): Future[void] {.closure, gcsafe.}
) {.async.} =
  let (address, client) = await server.socket.acceptAddr()
  dispatchClient(server, client, address, callback)

proc serve*(server: AsyncHttpServer, port: Port,
            callback: proc(request: Request): Future[void] {.closure, gcsafe.},
            address = "", assumedDescriptorsPerRequest = -1,
            domain = AF_INET) {.async.} =
  listen(server, port, address, domain)
  while true:
    if shouldAcceptRequest(server, assumedDescriptorsPerRequest):
      let (address, client) = await server.socket.acceptAddr()
      dispatchClient(server, client, address, callback)
    else:
      await sleepAsync(100)

# ------------------------------------------------------------------------------
# API: Close the listening socket.
# ------------------------------------------------------------------------------
proc close*(server: AsyncHttpServer) =
  server.socket.close()
