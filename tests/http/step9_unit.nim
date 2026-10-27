# Step 9 authority, CIDR, and metadata boundary unit tests.
import std/[unittest, net, httpcore]
import jestersimple/private/[trustboundary, utils]

suite "Step 9 request origin trust":
  test "Host authority syntax and port boundaries":
    check parseAuthority("localhost:5487").valid
    check parseAuthority("localhost:5487").port == 5487
    check parseAuthority("[::1]:8080").valid
    check parseAuthority("example.com:65535").valid
    for host in ["", "host:0", "host:65536", "host:bad", "evil@host",
                 "evil.com/path", "evil com", "[broken", "[::1]extra",
                 "http://example.com", "host:80:90", "example..com"]:
      check not parseAuthority(host).valid

  test "IPv4 and IPv6 trusted peer CIDR matching":
    check containsIp("127.0.0.0/8", "127.0.0.1")
    check not containsIp("127.0.0.1/32", "127.0.0.2")
    check containsIp("2001:db8::/32", "2001:db8::1234")
    check not containsIp("2001:db8::/32", "2001:db9::1")
    check not containsIp("192.0.2.0/33", "192.0.2.1")
    check not containsIp("127.0.0.0/8", "::1")

  test "reject invalid proxy and canonical URL settings":
    let settings = Settings(port: Port(5487), trustedProxies: @["abc.invalid"])
    expect ValueError:
      validateOriginSettings(settings)
    settings.trustedProxies = @["127.0.0.1/32"]
    validateOriginSettings(settings)
    settings.publicBaseUrl = "https://gateway.example.test:8443"
    validateOriginSettings(settings)
    settings.publicBaseUrl = "https://user@evil.test/"
    expect ValueError:
      validateOriginSettings(settings)

  test "untrusted socket peer ignores forged headers":
    let settings = Settings(port: Port(5487))
    var headers = newHttpHeaders()
    headers["Host"] = "localhost:5487"
    headers["REMOTE_ADDR"] = "10.0.0.10"
    headers["X-Forwarded-For"] = "198.51.100.1"
    headers["X-Forwarded-Proto"] = "https"
    headers["X-Forwarded-Host"] = "evil.test"
    let o = resolveOrigin("192.0.2.12", headers, settings)
    check o.ip == "192.0.2.12"
    check not o.secure
    check o.host == "localhost"
    check o.port == 5487

  test "trusted Forwarded chain stops at first untrusted hop":
    let settings = Settings(port: Port(5488),
      trustedProxies: @["127.0.0.1/32"], allowedHosts: @["gw.example.test"])
    var h = newHttpHeaders()
    h["Host"] = "localhost:5488"
    h["Forwarded"] = "for=203.0.113.8;proto=http;host=evil.test, " &
      "for=192.0.2.4;proto=https;host=gw.example.test"
    let o = resolveOrigin("127.0.0.1", h, settings)
    check o.ip == "192.0.2.4"
    check o.secure
    check o.host == "gw.example.test"
    check o.port == 443

  test "publicBaseUrl overrides client-controlled Host":
    let settings = Settings(port: Port(5489),
      publicBaseUrl: "https://gateway.example.test:8443")
    var h = newHttpHeaders()
    h["Host"] = "attacker.example"
    let o = resolveOrigin("127.0.0.1", h, settings)
    check o.host == "gateway.example.test"
    check o.port == 8443
    check o.secure
