# JS-08: an explicit host allowlist must be a closed set for URL origins.
import std/[unittest, net, httpcore]
import jestersimple/private/[trustboundary, utils]

# ------------------------------------------------------------------------------
# Resolve the same request headers under independently configured host policies.
# ------------------------------------------------------------------------------
proc originFor(settings: Settings, host: string, peer = "203.0.113.8",
               forwarded = "", xForwardedHost = "",
               forwardedProto = ""): RequestOrigin =
  var headers = newHttpHeaders()
  headers["Host"] = host
  if forwarded.len > 0:
    headers["Forwarded"] = forwarded
  if xForwardedHost.len > 0:
    headers["X-Forwarded-Host"] = xForwardedHost
  if forwardedProto.len > 0:
    headers["X-Forwarded-Proto"] = forwardedProto
  result = resolveOrigin(peer, headers, settings)

suite "JS-08 allowedHosts closed-set semantics":
  test "explicit allowlist rejects localhost, loopback, and bind address":
    let settings = Settings(port: Port(5558), bindAddr: "127.0.0.1",
      allowedHosts: @["gw.example.test"])
    for host in ["localhost", "LOCALHOST:5558", "127.0.0.1:5558",
                 "[::1]:5558", "attacker.example"]:
      let origin = originFor(settings, host)
      check origin.host == ""
      check origin.port == 5558

  test "explicit allowlist accepts only case-insensitive exact host":
    let settings = Settings(port: Port(5558), bindAddr: "127.0.0.1",
      allowedHosts: @["gw.example.test"])
    let valid = originFor(settings, "Gw.Example.Test:9443")
    check valid.host == "gw.example.test"
    check valid.port == 9443
    for host in ["badgw.example.test", "gw.example.test.evil",
                 "other.example.test"]:
      check originFor(settings, host).host == ""

  test "an empty list preserves local and bind-address fallback":
    let settings = Settings(port: Port(5558), bindAddr: "192.0.2.20")
    for host in ["localhost", "127.0.0.1", "[::1]", "192.0.2.20"]:
      check originFor(settings, host).host.len > 0
    check originFor(settings, "outside.example").host == ""

  test "wildcard listen address is not a trusted host":
    let settings = Settings(port: Port(5558), bindAddr: "0.0.0.0")
    check originFor(settings, "0.0.0.0").host == ""

  test "explicit allowlist may include localhost deliberately":
    let settings = Settings(port: Port(5558), bindAddr: "127.0.0.1",
      allowedHosts: @["gw.example.test", "localhost"])
    check originFor(settings, "LOCALHOST:5558").host == "localhost"
    check originFor(settings, "127.0.0.1").host == ""

  test "trusted X-Forwarded-Host must also satisfy explicit allowlist":
    let settings = Settings(port: Port(5558), bindAddr: "127.0.0.1",
      trustedProxies: @["127.0.0.1/32"], allowedHosts: @["gw.example.test"])
    let rejected = originFor(settings, "gw.example.test", "127.0.0.1",
      xForwardedHost = "localhost", forwardedProto = "https")
    check rejected.host == ""
    check rejected.secure
    let accepted = originFor(settings, "localhost", "127.0.0.1",
      xForwardedHost = "GW.EXAMPLE.TEST:8443", forwardedProto = "https")
    check accepted.host == "gw.example.test"
    check accepted.port == 8443
    check accepted.secure

  test "trusted RFC Forwarded host must satisfy explicit allowlist":
    let settings = Settings(port: Port(5558), bindAddr: "127.0.0.1",
      trustedProxies: @["127.0.0.1/32"], allowedHosts: @["gw.example.test"])
    let rejected = originFor(settings, "gw.example.test", "127.0.0.1",
      forwarded = "for=198.51.100.3;proto=https;host=localhost")
    check rejected.host == ""
    let accepted = originFor(settings, "localhost", "127.0.0.1",
      forwarded = "for=198.51.100.3;proto=https;host=gw.example.test")
    check accepted.host == "gw.example.test"
    check accepted.secure

  test "untrusted peer cannot override request host with forwarding":
    let settings = Settings(port: Port(5558), bindAddr: "127.0.0.1",
      trustedProxies: @["127.0.0.1/32"], allowedHosts: @["gw.example.test"])
    let origin = originFor(settings, "gw.example.test", "198.51.100.8",
      xForwardedHost = "localhost", forwardedProto = "https")
    check origin.host == "gw.example.test"
    check not origin.secure

  test "configured publicBaseUrl independently overrides request host":
    let settings = Settings(port: Port(5558), bindAddr: "127.0.0.1",
      allowedHosts: @["gw.example.test"],
      publicBaseUrl: "https://fixed.example.test:8443")
    validateOriginSettings(settings)
    let origin = originFor(settings, "localhost")
    check origin.host == "fixed.example.test"
    check origin.port == 8443
    check origin.secure

  test "valid explicit hosts and malformed entries are checked at startup":
    validateOriginSettings(Settings(port: Port(5558),
      allowedHosts: @["gw.example.test", "localhost", "[::1]"]))
    for host in ["gw.example.test:8443", "*.example.test", "bad@host"]:
      expect ValueError:
        validateOriginSettings(Settings(port: Port(5558),
          allowedHosts: @[host]))
