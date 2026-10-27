# Step 10: pure URL-encoded parameter regression tests.
import std/[unittest, tables]
import jestersimple/private/[queryparams, utils]

suite "Step 10 URL-encoded parameter parsing":
  test "double-encoded characters are decoded only once":
    var fields: seq[(string, string)] = @[]
    for key, value in decodedFormPairs("k=%252F&literal=%2525&slash=%2F"):
      fields.add (key, value)
    check fields == @[("k", "%2F"), ("literal", "%25"), ("slash", "/")]

  test "plus conversion and escaped delimiters":
    var fields: seq[(string, string)] = @[]
    for key, value in decodedFormPairs("a+b=1+2&key%26x=val%3D1%26n&eq=a=b"):
      fields.add (key, value)
    check fields == @[("a b", "1 2"), ("key&x", "val=1&n"),
                      ("eq", "a=b")]

  test "duplicates empty fields and missing equals":
    var fields: seq[(string, string)] = @[]
    for key, value in decodedFormPairs("a=1&&a=&flag&=x&tail="):
      fields.add (key, value)
    check fields == @[("a", "1"), ("a", ""), ("flag", ""),
                      ("", "x"), ("tail", "")]

  test "UTF-8 bytes pass through exactly":
    var fields: seq[(string, string)] = @[]
    for key, value in decodedFormPairs("%E5%90%8D=%E6%97%A5%E6%9C%AC"):
      fields.add (key, value)
    check fields == @[("名", "日本")]

  test "invalid percent encoding and NUL are rejected":
    for input in ["a=%", "a=%2", "a=%GG", "a=%0G", "a=%00", "a=\0"]:
      check not validUrlEncoded(input)
      expect(ValueError):
        for key, value in decodedFormPairs(input):
          discard key
          discard value
    check validUrlEncoded("x=%25%2f+ok")

  test "media type matching is exact and case insensitive":
    check isUrlEncodedForm("application/x-www-form-urlencoded")
    check isUrlEncodedForm("APPLICATION/X-WWW-FORM-URLENCODED; charset=UTF-8")
    check not isUrlEncodedForm("application/x-www-form-urlencoded-extra")
    check not isUrlEncodedForm("multipart/form-data")

  test "deprecated query helper decodes only once":
    var fields = initTable[string, string]()
    {.push warning[Deprecated]: off.}
    parseUrlQuery("?v=%252F&v=%25&a=1", fields)
    {.pop.}
    check fields["v"] == "%"
    check fields["a"] == "1"
