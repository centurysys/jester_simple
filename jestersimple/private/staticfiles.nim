# Linux-only file-descriptor based static asset resolution.
# The URL supplies only relative path components, never a pathname to open().
# POSIX openat() + O_NOFOLLOW pins each directory before resolving the next.

when not defined(linux):
  {.error: "Jester Simple static file resolver supports Linux only".}

import std/[posix, strutils, os]
import std/httpcore

# Linux fcntl.h flags. Nim 2.2 std/posix does not expose these three flags.
# Linux uses the same values on armhf, aarch64 and x86_64.
const
  LinuxNoFollow = 0x20000.cint
  LinuxDirectory = 0x10000.cint
  LinuxNonBlock = 0x800.cint
  StaticReadBlock* = 16 * 1024

proc openRelative(dirFd: cint, name: cstring, flags: cint): cint
  {.importc: "openat", header: "<fcntl.h>".}

type
  StaticOpen* = object
    status*: HttpCode
    fd*: cint
    size*: int64
    name*: string
    etag*: string

# ------------------------------------------------------------------------------
# Decode once, rejecting all path separators or dot segments after decoding.
# Keep non-ASCII filename bytes intact; Linux paths are byte strings.
# ------------------------------------------------------------------------------
proc hexValue(c: char): int {.inline.} =
  if c in {'0'..'9'}: return ord(c) - ord('0')
  if c in {'a'..'f'}: return ord(c) - ord('a') + 10
  if c in {'A'..'F'}: return ord(c) - ord('A') + 10
  return -1

proc staticSegments*(encodedPath: string): seq[string] =
  if encodedPath.len == 0 or encodedPath[0] != '/':
    raise newException(ValueError, "Invalid static path")

  var decoded = newStringOfCap(encodedPath.len)
  var i = 0
  while i < encodedPath.len:
    var c: char
    if encodedPath[i] == '%':
      if i + 2 >= encodedPath.len:
        raise newException(ValueError, "Invalid static percent encoding")
      let hi = hexValue(encodedPath[i + 1])
      let lo = hexValue(encodedPath[i + 2])
      if hi < 0 or lo < 0:
        raise newException(ValueError, "Invalid static percent encoding")
      c = char(hi * 16 + lo)
      i += 3
    else:
      c = encodedPath[i]
      inc i
    if ord(c) < 32 or ord(c) == 127 or c == '\\':
      raise newException(ValueError, "Invalid static path byte")
    decoded.add(c)

  if decoded == "/":
    return @[]
  if decoded.contains("//"):
    raise newException(ValueError, "Empty static path segment")
  if decoded.endsWith("/"):
    decoded.setLen(decoded.len - 1)

  var start = 1
  while start < decoded.len:
    var finish = start
    while finish < decoded.len and decoded[finish] != '/':
      inc finish
    let segment = decoded[start ..< finish]
    if segment.len == 0 or segment == "." or segment == "..":
      raise newException(ValueError, "Invalid static path segment")
    result.add(segment)
    start = finish + 1

# ------------------------------------------------------------------------------
# Metadata-only weak ETag. It is cheap to construct from the pinned FD and
# stable across requests to the same inode, without reading or hashing data.
# Include nanosecond mtime/ctime where available. The ETag intentionally does
# not claim byte-for-byte identity; files should be updated by atomic rename.
# ------------------------------------------------------------------------------
proc staticEtag(info: Stat): string =
  when compiles(info.st_mtim.tv_nsec):
    let msec = int64(info.st_mtim.tv_sec)
    let mnsec = int64(info.st_mtim.tv_nsec)
    let csec = int64(info.st_ctim.tv_sec)
    let cnsec = int64(info.st_ctim.tv_nsec)
  else:
    let msec = int64(info.st_mtime)
    let mnsec = 0'i64
    let csec = int64(info.st_ctime)
    let cnsec = 0'i64

  result = "W/\"" &
    $int64(info.st_dev) & "-" & $int64(info.st_ino) & "-" &
    $int64(info.st_size) & "-" &
    $msec & "-" & $mnsec & "-" & $csec & "-" & $cnsec & "\""

# ------------------------------------------------------------------------------
# RFC 9110 If-None-Match uses weak comparison for GET/HEAD; a matching weak
# or strong quoted tag, a comma-separated list, or * can produce HTTP 304.
# Do not split inside a quoted opaque tag.
# ------------------------------------------------------------------------------
proc sameWeakTag(item, currentTag: string): bool =
  var candidate = item.strip()
  if candidate == "*":
    return true
  if candidate.startsWith("W/"):
    candidate = candidate.substr(2)
  let current = (if currentTag.startsWith("W/"):
                   currentTag.substr(2) else: currentTag)
  if candidate.len < 2 or candidate[0] != '"' or candidate[^1] != '"':
    return false
  result = candidate == current

proc ifNoneMatchMatches*(header, currentTag: string): bool =
  if header.len == 0 or currentTag.len == 0:
    return false
  var start = 0
  var inQuotes = false
  for i, c in header:
    if c == '"':
      inQuotes = not inQuotes
    elif c == ',' and not inQuotes:
      if sameWeakTag(header[start ..< i], currentTag):
        return true
      start = i + 1
  if inQuotes:
    return false
  return sameWeakTag(header[start ..< header.len], currentTag)

# ------------------------------------------------------------------------------
# Validate the object via the opened FD, not a path that may be replaced.
# ------------------------------------------------------------------------------
proc checkOpened(fd: cint, name: string): StaticOpen =
  result = StaticOpen(status: Http404, fd: -1, name: name)
  var info: Stat
  if fstat(fd, info) != 0:
    return
  if not S_ISREG(info.st_mode):
    result.status = Http403
    return
  if (cint(info.st_mode) and S_IROTH) == 0:
    # Preserve the historical static-file policy of requiring other-read.
    result.status = Http403
    return
  if int64(info.st_size) < 0:
    result.status = Http403
    return
  result.status = Http200
  result.fd = fd
  result.size = int64(info.st_size)
  result.etag = staticEtag(info)

# ------------------------------------------------------------------------------
# The root is a trusted administrator setting; every URL-derived component is
# opened relative to a pinned directory and may not be a symlink.
# ------------------------------------------------------------------------------
proc openConfinedStatic*(root, encodedPath: string): StaticOpen =
  result = StaticOpen(status: Http404, fd: -1)
  var parts: seq[string]
  try:
    parts = staticSegments(encodedPath)
  except ValueError:
    result.status = Http400
    return

  # URL-derived leading-dot components are private by default, including
  # percent-encoded names and hidden directories anywhere below staticDir.
  # Return 404 to avoid disclosing whether the hidden entry exists.
  # This policy applies only to automatic static URL resolution: explicit
  # sendFile paths are selected by the application and remain unrestricted.
  for segment in parts:
    if segment.len > 0 and segment[0] == '.':
      return

  var current = posix.open(root.cstring,
    O_RDONLY or O_CLOEXEC or LinuxNoFollow or LinuxDirectory)
  if current < 0:
    return

  var display = ""
  try:
    for idx, segment in parts:
      let last = idx == parts.high
      let flags = O_RDONLY or O_CLOEXEC or LinuxNoFollow or
        (if last: LinuxNonBlock else: LinuxDirectory)
      let nextFd = openRelative(current, segment.cstring, flags)
      if nextFd < 0:
        return
      discard posix.close(current)
      current = nextFd
      display = segment

    var info: Stat
    if fstat(current, info) != 0:
      return
    if S_ISDIR(info.st_mode):
      for indexName in ["index.html", "index.htm"]:
        let nextFd = openRelative(current, indexName.cstring,
          O_RDONLY or O_CLOEXEC or LinuxNoFollow or LinuxNonBlock)
        if nextFd >= 0:
          let checked = checkOpened(nextFd, indexName)
          if checked.status == Http200:
            result = checked
            return
          discard posix.close(nextFd)
          if checked.status == Http403:
            result.status = Http403
            return
      return

    if encodedPath.endsWith("/"):
      return
    result = checkOpened(current, display)
    if result.status == Http200:
      current = -1 # The caller now owns this descriptor.
  finally:
    if current >= 0:
      discard posix.close(current)

# ------------------------------------------------------------------------------
# Explicit sendFile is an application-provided path, not an HTTP URL.
# It may intentionally refer outside staticDir. It is nevertheless pinned to
# one FD before permission checks and reads, avoiding the original open race.
# ------------------------------------------------------------------------------
proc openExplicitStatic*(path: string): StaticOpen =
  result = StaticOpen(status: Http404, fd: -1)
  let fd = posix.open(path.cstring, O_RDONLY or O_CLOEXEC or LinuxNonBlock)
  if fd < 0:
    return
  result = checkOpened(fd, path.splitFile.name & path.splitFile.ext)
  if result.status != Http200:
    discard posix.close(fd)

proc closeStatic*(asset: var StaticOpen) =
  if asset.fd >= 0:
    discard posix.close(asset.fd)
    asset.fd = -1

# ------------------------------------------------------------------------------
# Read only from the pinned descriptor. Short reads are accumulated; a changed
# file that reaches EOF too early is treated as an I/O failure, not as success.
# ------------------------------------------------------------------------------
proc readStaticChunk*(fd: cint, size: int): string =
  if size <= 0:
    return ""
  result = newString(size)
  var obtained = 0
  while obtained < size:
    let n = posix.read(fd, addr result[obtained], size - obtained)
    if n < 0:
      raise newException(IOError, "Static file read failed")
    if n == 0:
      break
    obtained += n
  result.setLen(obtained)

proc readStaticExactly*(fd: cint, size: int): string =
  result = readStaticChunk(fd, size)
  if result.len != size:
    raise newException(IOError, "Static file size changed while reading")
