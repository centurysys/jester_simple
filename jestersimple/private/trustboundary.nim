# Linux-only HTTP origin trust boundaries for Jester Simple.
# Untrusted forwarding headers are never used for application metadata.
import std/[net, strutils, uri]
import std/httpcore
import ./utils

# ------------------------------------------------------------------------------
# Parsed request metadata. Resolved once per HTTP request, not per accessor.
# ------------------------------------------------------------------------------
type
  RequestOrigin* = object
    ip*: string
    host*: string
    port*: int
    secure*: bool

  Authority* = object
    valid*: bool
    host*: string
    port*: int
    hasPort*: bool

# ------------------------------------------------------------------------------
# Parse Host and forwarded authority without permitting userinfo, whitespace,
# controls, URL delimiters, or ambiguous IPv6 and port syntax.
# ------------------------------------------------------------------------------
proc parseAuthority*(raw: string): Authority =
  if raw.len == 0 or raw.len > 320:
    return
  for c in raw:
    if ord(c) < 33 or ord(c) > 126 or c in {'@', '/', '?', '#', '%', '\\'}:
      return
  var hostPart, portPart: string
  if raw[0] == '[':
    let endBracket = raw.find(']')
    if endBracket <= 1:
      return
    hostPart = raw[0 .. endBracket]
    try:
      if parseIpAddress(raw[1 ..< endBracket]).family != IPv6:
        return
    except ValueError:
      return
    let tail = raw[endBracket+1 .. ^1]
    if tail.len > 0:
      if tail[0] != ':' or tail.len == 1:
        return
      portPart = tail[1 .. ^1]
  else:
    let colon = raw.find(':')
    if colon >= 0:
      if raw.find(':', colon + 1) >= 0:
        return
      hostPart = raw[0 ..< colon]
      portPart = raw[colon+1 .. ^1]
      if portPart.len == 0:
        return
    else:
      hostPart = raw
    if hostPart.len == 0 or hostPart.len > 253:
      return
    # Hostnames are ASCII A-labels. IDNs must be supplied as punycode.
    for label in hostPart.split('.'):
      if label.len == 0 or label.len > 63 or
          label[0] == '-' or label[^1] == '-':
        return
      for c in label:
        if c notin {'A'..'Z', 'a'..'z', '0'..'9', '-'}:
          return
  result.host = hostPart.toLowerAscii()
  if portPart.len > 0:
    var portNum = 0
    for c in portPart:
      if c notin {'0'..'9'}:
        return Authority()
      portNum = portNum * 10 + ord(c) - ord('0')
      if portNum > 65535:
        return Authority()
    if portNum < 1:
      return Authority()
    result.port = portNum
    result.hasPort = true
  result.valid = true

# ------------------------------------------------------------------------------
# CIDR matching for literal IPv4 and IPv6 network ranges. No DNS lookups.
# ------------------------------------------------------------------------------
proc containsIp*(network, peer: string): bool =
  let slash = network.find('/')
  let address = if slash < 0: network else: network[0 ..< slash]
  var netIp, peerIp: IpAddress
  try:
    netIp = parseIpAddress(address)
    peerIp = parseIpAddress(peer)
  except ValueError:
    return false
  if netIp.family != peerIp.family:
    return false
  var bits = if netIp.family == IPv4: 32 else: 128
  if slash >= 0:
    let prefix = network[slash+1 .. ^1]
    if prefix.len == 0:
      return false
    bits = 0
    for c in prefix:
      if c notin {'0'..'9'}:
        return false
      bits = bits * 10 + ord(c) - ord('0')
      if bits > 128:
        return false
    if (netIp.family == IPv4 and bits > 32):
      return false
  let totalBytes = if netIp.family == IPv4: 4 else: 16
  for i in 0 ..< totalBytes:
    if bits <= 0: break
    let a = if netIp.family == IPv4: netIp.address_v4[i] else: netIp.address_v6[i]
    let b = if peerIp.family == IPv4: peerIp.address_v4[i] else: peerIp.address_v6[i]
    let bitCount = min(bits, 8)
    let mask = uint8((255 shl (8 - bitCount)) and 255)
    if (a and mask) != (b and mask):
      return false
    bits -= bitCount
  result = true

# ------------------------------------------------------------------------------
# Reject an unrestricted CIDR as a proxy trust rule, including zero-padded /0.
# containsIp remains a general CIDR matcher: its /0 behavior is intentional.
# ------------------------------------------------------------------------------
proc isUnrestrictedProxyCidr(network: string): bool =
  let slash = network.find('/')
  if slash < 0 or slash + 1 >= network.len:
    return false
  for i in slash + 1 ..< network.len:
    if network[i] != '0':
      return false
  result = true

proc isTrustedPeer*(peer: string, trusted: openArray[string]): bool =
  for network in trusted:
    # Settings are mutable: do not trust /0 even after post-startup changes.
    if not isUnrestrictedProxyCidr(network) and containsIp(network, peer):
      return true

proc validateOriginSettings*(settings: Settings) =
  for network in settings.trustedProxies:
    let slash = network.find('/')
    let proxyAddress = if slash < 0: network else: network[0 ..< slash]
    try:
      discard parseIpAddress(proxyAddress)
    except ValueError:
      raise newException(ValueError, "Invalid trusted proxy address")
    if isUnrestrictedProxyCidr(network):
      raise newException(ValueError,
        "Unrestricted trusted proxy CIDR is not allowed")
    if not containsIp(network, proxyAddress):
      raise newException(ValueError, "Invalid trusted proxy CIDR")
  for host in settings.allowedHosts:
    let parsed = parseAuthority(host)
    if not parsed.valid or parsed.hasPort:
      raise newException(ValueError, "Invalid allowed host")
  if settings.publicBaseUrl.len > 0:
    var u: Uri
    try:
      u = parseUri(settings.publicBaseUrl)
    except ValueError:
      raise newException(ValueError, "Invalid public base URL")
    if u.scheme notin ["http", "https"] or u.hostname.len == 0 or
        u.username.len > 0 or u.password.len > 0 or
        u.path notin ["", "/"] or u.query.len > 0 or u.anchor.len > 0:
      raise newException(ValueError, "Invalid public base URL")
    let authority = u.hostname & (if u.port.len > 0: ":" & u.port else: "")
    if not parseAuthority(authority).valid:
      raise newException(ValueError, "Invalid public base URL host")

# ------------------------------------------------------------------------------
# Parse comma or semicolon separated RFC 7239 elements without splitting
# inside quoted strings. Reject unmatched quotes and escapes.
# ------------------------------------------------------------------------------
proc splitQuoted(s: string, delim: char): seq[string] =
  var quoted = false
  var escaped = false
  var beginAt = 0
  for i, c in s:
    if escaped:
      escaped = false
    elif quoted and c == '\\':
      escaped = true
    elif c == '"':
      quoted = not quoted
    elif c == delim and not quoted:
      result.add(s[beginAt ..< i].strip())
      beginAt = i + 1
  if quoted or escaped:
    return @[]
  result.add(s[beginAt .. ^1].strip())

proc quotedValue(s: string): string =
  if s.len >= 2 and s[0] == '"' and s[^1] == '"':
    var i = 1
    while i < s.len - 1:
      if s[i] == '\\':
        inc i
        if i >= s.len - 1:
          return ""
      elif s[i] == '"':
        return ""
      result.add s[i]
      inc i
  elif '"' notin s:
    result = s

proc parseForwardedNode(s: string): string =
  let clean = s.strip()
  if clean.len == 0 or clean.toLowerAscii() == "unknown" or clean[0] == '_':
    return ""
  var nodeAddress = clean
  if nodeAddress[0] == '[':
    let bracket = nodeAddress.find(']')
    if bracket < 1:
      return ""
    let suffix = nodeAddress[bracket+1 .. ^1]
    if suffix.len > 0:
      if suffix[0] != ':' or suffix.len == 1:
        return ""
      for c in suffix[1 .. ^1]:
        if c notin {'0'..'9'}:
          return ""
    nodeAddress = nodeAddress[1 ..< bracket]
  elif ':' in nodeAddress and '.' in nodeAddress:
    # IPv4:port. Strip the port only if the remainder is valid IPv4.
    let colon = nodeAddress.rfind(':')
    if colon > 0 and isIpAddress(nodeAddress[0 ..< colon]):
      for c in nodeAddress[colon+1 .. ^1]:
        if c notin {'0'..'9'}:
          return ""
      nodeAddress = nodeAddress[0 ..< colon]
  try:
    result = $parseIpAddress(nodeAddress)
  except ValueError:
    discard

proc clientFromChain(values: seq[string], peer: string,
                     trusted: seq[string]): string =
  result = peer
  if values.len == 0 or values.len > 32:
    return
  var current = peer
  for i in countdown(values.high, 0):
    if not isTrustedPeer(current, trusted):
      break
    let next = parseForwardedNode(values[i])
    if next.len == 0:
      return peer
    current = next
  result = current

proc isAllowedHost(host: string, allowed: seq[string], bindAddr: string): bool =
  if host in ["localhost", "127.0.0.1", "[::1]"]:
    return true
  if bindAddr.len > 0 and bindAddr notin ["0.0.0.0", "::"] and
      cmpIgnoreCase(host, bindAddr) == 0:
    return true
  for configured in allowed:
    if cmpIgnoreCase(host, configured) == 0:
      return true

# ------------------------------------------------------------------------------
# Ignore all forwarded information unless the immediate TCP peer is trusted.
# Never combine RFC 7239 Forwarded with X-Forwarded-* metadata.
# All external hostnames still require an allowlist or publicBaseUrl.
# ------------------------------------------------------------------------------
proc resolveOrigin*(peer: string, headers: HttpHeaders,
                    settings: Settings): RequestOrigin =
  result.ip = peer
  result.secure = false
  result.port = int(settings.port)
  var rawHost: string = headers.getOrDefault("Host")
  let proxied = isTrustedPeer(peer, settings.trustedProxies)
  if proxied:
    let forwarded: string = headers.getOrDefault("Forwarded")
    let mixedFamilies = forwarded.len > 0 and (
      headers.hasKey("X-Forwarded-For") or
      headers.hasKey("X-Forwarded-Proto") or
      headers.hasKey("X-Forwarded-Host"))
    if forwarded.len > 0 and not mixedFamilies:
      let entries = splitQuoted(forwarded, ',')
      if entries.len > 0 and entries.len <= 32:
        var chain: seq[string] = @[]
        var proto, fhost: string
        var valid = true
        for entry in entries:
          let params = splitQuoted(entry, ';')
          if params.len == 0:
            valid = false
            break
          var client, scheme, hostname: string
          for item in params:
            let eq = item.find('=')
            if eq <= 0:
              valid = false
              break
            let key = item[0 ..< eq].strip().toLowerAscii()
            let val = quotedValue(item[eq+1 .. ^1].strip())
            if val.len == 0:
              valid = false
              break
            case key
            of "for":
              if client.len > 0: valid = false
              client = val
            of "proto":
              if scheme.len > 0: valid = false
              scheme = val.toLowerAscii()
            of "host":
              if hostname.len > 0: valid = false
              hostname = val
            else: discard
          if not valid or client.len == 0:
            valid = false
            break
          chain.add client
          proto = scheme
          fhost = hostname
        if valid:
          result.ip = clientFromChain(chain, peer, settings.trustedProxies)
          if proto in ["http", "https"]:
            result.secure = proto == "https"
          if fhost.len > 0:
            rawHost = fhost
    elif forwarded.len == 0:
      let xff: string = headers.getOrDefault("X-Forwarded-For")
      if xff.len > 0:
        result.ip = clientFromChain(xff.split(','), peer, settings.trustedProxies)
      let xfp: string = headers.getOrDefault("X-Forwarded-Proto")
      if xfp.len > 0:
        let value = xfp.split(',')[^1].strip().toLowerAscii()
        if value in ["http", "https"]:
          result.secure = value == "https"
      let xfh: string = headers.getOrDefault("X-Forwarded-Host")
      if xfh.len > 0:
        rawHost = xfh.split(',')[^1].strip()

  let authority = parseAuthority(rawHost)
  if authority.valid and isAllowedHost(authority.host, settings.allowedHosts, settings.bindAddr):
    result.host = authority.host
    if authority.hasPort:
      result.port = authority.port
    elif proxied:
      result.port = if result.secure: 443 else: 80

  if settings.publicBaseUrl.len > 0:
    let base = parseUri(settings.publicBaseUrl)
    result.host = base.hostname
    result.secure = base.scheme == "https"
    if base.port.len > 0:
      result.port = parseInt(base.port)
    else:
      result.port = if result.secure: 443 else: 80
