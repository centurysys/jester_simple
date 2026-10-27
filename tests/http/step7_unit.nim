# Step 7: pure HTML escaping and URI normalization checks.
import std/[strutils, unittest]
import jestersimple
import jestersimple/private/errorpages

suite "Step 7 error pages and URI endpoints":
  test "default error status text is escaped":
    let page = errorpages.error("<img src=x onerror=alert(1)>&", "1<2")
    check page.contains("&lt;img")
    check page.contains("&gt;&amp;")
    check page.contains("1&lt;2")
    check not page.contains("<img")

  test "exception detail helper is escaped":
    let page = errorpages.routeException(
      "<script>alert('x') & \"y\"</script>", "v<1")
    check page.contains("&lt;script&gt;")
    check page.contains("&amp;")
    check page.contains("&#39;")
    check page.contains("&quot;")
    check page.contains("v&lt;1")
    check not page.contains("<script>")

  test "empty URI remains empty":
    check normalizeUri("") == ""

  test "root URI is retained":
    check normalizeUri("/") == "/"

  test "one trailing slash is removed":
    check normalizeUri("/abc/") == "/abc"
    check normalizeUri("/abc//") == "/abc/"
    check normalizeUri("/abc") == "/abc"
