# JS-11: immutable startup snapshot, resource validation and descriptor budget.
import std/[net, strutils]
import jestersimple
import jestersimple/private/[utils, httptransport]

# ------------------------------------------------------------------------------
# API: A running server must not share caller-owned mutable allowlist sequences.
# ------------------------------------------------------------------------------
proc testSnapshot() =
  let original = newSettings(
    trustedProxies = @["127.0.0.1/32"],
    allowedHosts = @["gw.example.test"])
  let copied = snapshotSettings(original)
  doAssert copied != original
  doAssert copied.allowedHosts == @["gw.example.test"]
  original.allowedHosts[0] = "evil.example.test"
  original.trustedProxies[0] = "0.0.0.0/0"
  original.maxConnections = 1
  doAssert copied.allowedHosts == @["gw.example.test"]
  doAssert copied.trustedProxies == @["127.0.0.1/32"]
  doAssert copied.maxConnections == 64

# ------------------------------------------------------------------------------
# API: Reject nonsensical resource settings before the listener starts.
# ------------------------------------------------------------------------------
proc testSettingsValidation() =
  validateServerSettings(newSettings())
  for field in 0..10:
    let s = newSettings()
    case field
    of 0: s.staticDir = ""
    of 1: s.maxBody = -1
    of 2: s.maxConnections = 0
    of 3: s.maxHeaderBytes = 0
    of 4: s.maxHeaderFields = 0
    of 5: s.headerTimeoutMs = 0
    of 6: s.bodyTimeoutMs = 0
    of 7: s.keepAliveTimeoutMs = 0
    of 8: s.managedSendTimeoutMs = 0
    of 9: s.responseStartTimeoutMs = 0
    of 10: s.streamTotalTimeoutMs = 0
    else: discard
    var rejected = false
    try:
      validateServerSettings(s)
    except ValueError:
      rejected = true
    doAssert rejected, "Invalid settings field not rejected: " & $field
  var rejectedNil = false
  try:
    discard snapshotSettings(nil)
  except ValueError:
    rejectedNil = true
  doAssert rejectedNil

# ------------------------------------------------------------------------------
# API: Verify reserve limits without relying on an OS-dependent RLIMIT.
# ------------------------------------------------------------------------------
proc testFdHeadroom() =
  doAssert hasDescriptorHeadroom(10, 16, 5)
  doAssert not hasDescriptorHeadroom(11, 16, 5)
  doAssert not hasDescriptorHeadroom(16, 16, 0)
  doAssert not hasDescriptorHeadroom(17, 16, 0)
  doAssert not hasDescriptorHeadroom(0, 0, 5)
  doAssert not hasDescriptorHeadroom(-1, 100, 5)
  doAssert hasDescriptorHeadroom(10, 16, -1)
  doAssert not hasDescriptorHeadroom(11, 16, -1)
  doAssert hasDescriptorHeadroom(10, 16, 0)
  doAssert not hasDescriptorHeadroom(10, 16, 6)

when isMainModule:
  testSnapshot()
  testSettingsValidation()
  testFdHeadroom()
  echo "JS11_UNIT_PASS"
