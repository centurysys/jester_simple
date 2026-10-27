# Step 8: pure response-header and cookie serialization checks.
import std/[unittest, strutils, httpcore, options]
import jestersimple
import jestersimple/private/[responsevalidation, utils]

suite "Step 8 response header validation":
  test "ordinary header and token punctuation":
    validateHeaderPair("X-Trace.Id", "safe-value")
    validateRawHeaders(@[(key: "Content-Type", val: "text/plain")])

  test "invalid names and control bytes":
    for key in ["", "Bad Header", "X:Bad", "X\cFoo", "X\LFoo", "X\0Foo"]:
      expect(ValueError):
        validateHeaderPair(key, "ok")
    for value in ["a\c\LInjected: yes", "a\LFoo", "abc\0def", "abc\tdef"]:
      expect(ValueError):
        validateHeaderPair("X-Test", value)

  test "case-insensitive duplicate content length":
    expect(ValueError):
      validateRawHeaders(@[(key: "Content-Length", val: "2"),
                           (key: "content-length", val: "2")], 2)
    expect(ValueError):
      validateRawHeaders(@[(key: "Content-Length", val: "3")], 2)
    expect(ValueError):
      validateRawHeaders(@[(key: "Content-Length", val: "2, 2")], 2)
    expect(ValueError):
      validateRawHeaders(@[(key: "Content-Length", val: "-1")], 2)
    expect(ValueError):
      validateRawHeaders(@[(key: "Content-Length", val: "999999999999999999999999")])
    validateRawHeaders(@[(key: "Content-Length", val: "2")], 2)

  test "transfer encoding rejected even on raw header-only sends":
    expect(ValueError):
      validateRawHeaders(@[(key: "Transfer-Encoding", val: "chunked")])
    expect(ValueError):
      validateRawHeaders(@[(key: "Transfer-Encoding", val: "chunked"),
                           (key: "Content-Length", val: "2")])

  test "HttpHeaders validates each Set-Cookie value":
    let headers = newHttpHeaders(@[(key: "Set-Cookie", val: "a=1"),
                                   (key: "set-cookie", val: "b=2")])
    validateHttpHeaders(headers)
    check headers["Set-Cookie", 0] == "a=1"
    check headers["Set-Cookie", 1] == "b=2"

  test "first cookie has a valid nonempty response field":
    var headers: ResponseHeaders = none(RawHeaders)
    setCookie(headers, "sid", "one", httpOnly=true)
    check headers.isSome
    if headers.isSome:
      check headers.get().len == 1
      check headers.get()[0].key == "Set-Cookie"
      check headers.get()[0].val == "sid=one; HttpOnly; SameSite=Lax"
      validateRawHeaders(headers.get())

  test "multiple cookies remain separate response fields":
    var headers: ResponseHeaders = none(RawHeaders)
    setCookie(headers, "sid", "one", httpOnly=true)
    setCookie(headers, "theme", "light", path="/")
    check headers.isSome
    if headers.isSome:
      let raw = headers.get()
      check raw.len == 2
      check raw[0].key == "Set-Cookie"
      check raw[0].val == "sid=one; HttpOnly; SameSite=Lax"
      check raw[1].key == "Set-Cookie"
      check raw[1].val == "theme=light; Path=/; SameSite=Lax"
      validateRawHeaders(raw)

  test "mixed case existing cookie preserves independent Set-Cookie":
    var headers: ResponseHeaders = none(RawHeaders)
    setHeader(headers, "set-cookie", "legacy=1")
    setCookie(headers, "second", "2")
    check headers.isSome
    if headers.isSome:
      let raw = headers.get()
      check raw.len == 2
      check raw[0].key == "set-cookie"
      check raw[0].val == "legacy=1"
      check raw[1].key == "Set-Cookie"
      check raw[1].val == "second=2; SameSite=Lax"
      validateRawHeaders(raw)

  test "cookie syntax disallows header and attribute injection":
    check makeCookie("sid", "abc", "", secure=true, httpOnly=true).contains("Secure")
    expect(ValueError):
      discard makeCookie("bad;name", "value", "")
    expect(ValueError):
      discard makeCookie("sid", "evil; admin=true", "")
    expect(ValueError):
      discard makeCookie("sid", "a\c\LInjected: yes", "")
    expect(ValueError):
      discard makeCookie("sid", "ok", "", domain="x.com; Secure")
    expect(ValueError):
      discard makeCookie("sid", "ok", "", path="/ok\LInjected")
    expect(ValueError):
      discard makeCookie("sid", "ok", "tomorrow; HttpOnly")

  test "quoted filename is escaped without CRLF acceptance":
    check attachmentDisposition("file\"name\\.txt") ==
      "attachment; filename=\"file\\\"name\\\\.txt\""
    check attachmentDisposition("") == "attachment"
    expect(ValueError):
      discard attachmentDisposition("report\c\LInjected: 1.txt")
