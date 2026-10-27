# JS-10: malformed route patterns must fail with ValueError, not IndexDefect.
import std/[tables, unittest]
import jestersimple/patterns

suite "JS-10 route pattern parser boundaries":
  test "empty and plain literal patterns remain valid":
    let emptyPattern = parsePattern("")
    check emptyPattern.len == 0
    check emptyPattern.match("").matched
    check not emptyPattern.match("/").matched

    let plain = parsePattern("/status")
    check plain.match("/status").matched
    check not plain.match("/status/extra").matched

  test "optional literal suffix works with and without the character":
    let pattern = parsePattern("/report.?")
    check pattern.match("/report").matched
    check pattern.match("/report.").matched
    check not pattern.match("/reports").matched

  test "optional slash and named field retain existing semantics":
    let optionalSlash = parsePattern("/path/?")
    check optionalSlash.match("/path").matched
    check optionalSlash.match("/path/").matched

    let named = parsePattern("/items/@id?")
    let withoutId = named.match("/items/")
    check withoutId.matched
    check withoutId.params["id"] == ""
    let withId = named.match("/items/42")
    check withId.matched
    check withId.params["id"] == "42"

  test "escaped special characters continue matching literally":
    let pattern = parsePattern("/escaped/\\@\\?\\\\")
    check pattern.match("/escaped/@?\\").matched
    check not pattern.match("/escaped/@?\\\\").matched

  test "leading and repeated question marks produce ValueError":
    for source in ["?", "?/path", "??", "/path/??"]:
      expect ValueError:
        discard parsePattern(source)

  test "trailing backslashes produce ValueError":
    for source in ["\\", "/path\\", "/escaped/\\@\\"]:
      expect ValueError:
        discard parsePattern(source)

  test "unsupported escape still produces ValueError":
    expect ValueError:
      discard parsePattern("/bad\\x")
