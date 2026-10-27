# JS-07: /0 must never act as a forwarding-header trust boundary.
import std/[unittest, net, httpcore]
import jestersimple/private/[trustboundary, utils]

# ------------------------------------------------------------------------------
# Verify IPv4/IPv6 CIDR matching remains general, while proxy policy is strict.
# ------------------------------------------------------------------------------
suite "JS-07 trusted proxy CIDR restrictions":
  test "generic CIDR matching retains mathematical /0 behavior":
    check containsIp("0.0.0.0/0", "198.51.100.23")
    check containsIp("2001:db8::/0", "2001:db8:1::1")
    check not containsIp("0.0.0.0/0", "2001:db8::1")

  test "reject any IPv4 /0 configuration, including noncanonical forms":
    for network in ["0.0.0.0/0", "192.0.2.14/0", "198.51.100.1/00",
                    "255.255.255.255/000"]:
      let settings = Settings(port: Port(5487), trustedProxies: @[network])
      expect ValueError:
        validateOriginSettings(settings)

  test "reject any IPv6 /0 configuration, including noncanonical forms":
    for network in ["::/0", "2001:db8::/0", "::1/00", "ffff::1/000"]:
      let settings = Settings(port: Port(5487), trustedProxies: @[network])
      expect ValueError:
        validateOriginSettings(settings)

  test "empty trust list and explicit narrow networks remain valid":
    validateOriginSettings(Settings(port: Port(5487)))
    for network in ["127.0.0.1", "127.0.0.1/32", "192.0.2.0/24",
                    "::1", "::1/128", "2001:db8::/32"]:
      validateOriginSettings(Settings(port: Port(5487),
        trustedProxies: @[network]))
    check isTrustedPeer("127.0.0.1", @["127.0.0.1/32"])
    check isTrustedPeer("::1", @["::1/128"])
    check not isTrustedPeer("127.0.0.2", @["127.0.0.1/32"])

  test "mutated settings cannot enable unrestricted IPv4 or IPv6 trust":
    for network in ["0.0.0.0/0", "192.0.2.14/00", "::/0", "::1/000"]:
      check not isTrustedPeer("203.0.113.9", @[network])
      check not isTrustedPeer("2001:db8::9", @[network])
    check isTrustedPeer("127.0.0.1",
      @["0.0.0.0/0", "127.0.0.1/32"])

  test "untrusted IPv4 peer cannot inject X-Forwarded metadata":
    let settings = Settings(port: Port(5487),
      trustedProxies: @["0.0.0.0/0"])
    var headers = newHttpHeaders()
    headers["Host"] = "localhost:5487"
    headers["X-Forwarded-For"] = "198.51.100.77"
    headers["X-Forwarded-Proto"] = "https"
    headers["X-Forwarded-Host"] = "attacker.example"
    let origin = resolveOrigin("203.0.113.4", headers, settings)
    check origin.ip == "203.0.113.4"
    check not origin.secure
    check origin.host == "localhost"

  test "untrusted IPv6 peer cannot inject Forwarded metadata":
    let settings = Settings(port: Port(5487), trustedProxies: @["::/000"])
    var headers = newHttpHeaders()
    headers["Host"] = "localhost:5487"
    headers["Forwarded"] = "for=198.51.100.77;proto=https"
    let origin = resolveOrigin("2001:db8::5", headers, settings)
    check origin.ip == "2001:db8::5"
    check not origin.secure

  test "valid trusted peer can still supply forwarding metadata":
    let settings = Settings(port: Port(5487),
      trustedProxies: @["127.0.0.1/32"])
    var headers = newHttpHeaders()
    headers["Host"] = "localhost:5487"
    headers["X-Forwarded-For"] = "198.51.100.77"
    headers["X-Forwarded-Proto"] = "https"
    let origin = resolveOrigin("127.0.0.1", headers, settings)
    check origin.ip == "198.51.100.77"
    check origin.secure
