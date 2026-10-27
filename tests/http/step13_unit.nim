# Step 13: parse URL components before they can become filesystem paths.
import std/[unittest]
import jestersimple/private/staticfiles

suite "static URL path segments":
  test "root and ordinary paths":
    check staticSegments("/") == newSeq[string]()
    check staticSegments("/sub/file.txt") == @["sub", "file.txt"]
    check staticSegments("/sub/") == @["sub"]

  test "percent decoding exactly once":
    check staticSegments("/a%20b.txt") == @["a b.txt"]
    check staticSegments("/%252e%252e") == @["%2e%2e"]
    check staticSegments("/%E3%81%82.txt") == @["あ.txt"]

  test "malformed percent encodings":
    for path in ["/%", "/%2", "/%GG", "/%0G"]:
      expect(ValueError):
        discard staticSegments(path)

  test "traversal and encoded separators":
    for path in ["/.", "/..", "/%2e%2e", "/sub/%2e%2e/out",
                 "/sub%2f..%2fsecret", "//etc/passwd", "/foo//bar",
                 "/%2fetc/passwd", "/a%5Cb", "/%00", "/%0a"]:
      expect(ValueError):
        discard staticSegments(path)
