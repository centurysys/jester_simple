# Step 14: conditional HTTP request validator comparison (Nim stdlib only).
import std/unittest
import jestersimple/private/staticfiles

suite "If-None-Match weak comparison":
  const tag = "W/\"12-34\""

  test "exact weak tag":
    check ifNoneMatchMatches(tag, tag)

  test "strong request tag compares weakly":
    check ifNoneMatchMatches("\"12-34\"", tag)

  test "comma-delimited list":
    check ifNoneMatchMatches("\"other\", W/\"12-34\"", tag)

  test "weak comparison in either direction":
    check ifNoneMatchMatches("W/\"12-34\"", "\"12-34\"")

  test "wildcard":
    check ifNoneMatchMatches("*", tag)

  test "missing or mismatched validator":
    check not ifNoneMatchMatches("", tag)
    check not ifNoneMatchMatches("\"another\"", tag)

  test "malformed validators do not match":
    check not ifNoneMatchMatches("12-34", tag)
    check not ifNoneMatchMatches("\"12-34", tag)

  test "commas inside quoted strings are not separators":
    check not ifNoneMatchMatches("\"other, W/\\\"12-34\\\"\"", tag)
