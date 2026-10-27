# Safe, diagnostic-only representation of outgoing HTTP response headers.
# Keep this separate from wire serialization: never modify the transmitted data.

import std/[httpcore, strutils]

const RedactedHeaderValue = "[REDACTED]"

# ------------------------------------------------------------------------------
# Preserve only a validated framing length in debug logs. All other header
# values, including unknown extension fields, may contain application secrets.
# ------------------------------------------------------------------------------
proc printableLength(key, value: string): bool =
  if cmpIgnoreCase(key, "Content-Length") != 0 or value.len == 0:
    return false
  for ch in value:
    if ch notin {'0'..'9'}:
      return false
  return true

# ------------------------------------------------------------------------------
# Format a redacted copy. RawHeaders duplicates remain distinct in the input;
# the formatter never changes the headers sent to the client.
# ------------------------------------------------------------------------------
proc formatHeadersForLog*(headers: openArray[tuple[key, val: string]]): string =
  var safe = newSeq[tuple[key, val: string]](headers.len)
  for i, header in headers:
    safe[i] = (
      key: header.key,
      val: (if printableLength(header.key, header.val):
              header.val
            else:
              RedactedHeaderValue)
    )
  result = $newHttpHeaders(safe)
