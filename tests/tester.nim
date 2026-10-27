# Copyright (C) 2018 Dominik Picheta
# MIT License - Look at license.txt for details.
import std/[unittest, httpclient, strutils, asyncdispatch, os, osproc]

const
  port = 5454
  address = "http://localhost:" & $port

var serverProcess: Process

# ------------------------------------------------------------------------------
# Stop the current test server and reclaim its process resources.
# ------------------------------------------------------------------------------
proc stopServer() =
  if serverProcess.isNil:
    return

  try:
    if serverProcess.running:
      serverProcess.terminate()
      if serverProcess.waitForExit(3000) == -1:
        serverProcess.kill()
        discard serverProcess.waitForExit(3000)
  finally:
    serverProcess.close()
    serverProcess = nil

# ------------------------------------------------------------------------------
# Compile a test application without shell commands or external Nim packages.
# ------------------------------------------------------------------------------
proc compileServer(source, executable: string) =
  let compiler = startProcess("nim", args = @[
    "c", "--mm:orc", "--hints:off", "--path:.",
    "--out:" & executable, source
  ], options = {poUsePath, poParentStreams})
  try:
    let code = compiler.waitForExit()
    doAssert code == 0, "Failed to compile " & source & ": exit " & $code
  finally:
    compiler.close()

# ------------------------------------------------------------------------------
# Start one Linux test server and wait until HTTP replies on loopback.
# ------------------------------------------------------------------------------
proc startServer(file: string) =
  stopServer()

  let source = "tests" / file
  let executable = source.changeFileExt(ExeExt)
  compileServer(source, executable)

  echo "Starting: ", executable
  serverProcess = startProcess(executable, options = {poParentStreams})

  for attempt in 0..<40:
    if not serverProcess.running:
      raise newException(IOError, "Test server exited before readiness: " & source)

    let probe = newHttpClient(timeout = 1000, maxRedirects = 0)
    try:
      discard probe.get(address)
      return
    except CatchableError:
      discard
    finally:
      probe.close()
    sleep(100)

  raise newException(IOError, "Test server did not become ready: " & source)

proc allTest() =
  startServer("alltest.nim")
  var client = newAsyncHttpClient(maxRedirects = 0)

  test "path outside appName returns 404 without exposing internals":
    let resp = waitFor client.get(address)
    let content = waitFor resp.body
    check resp.code == Http404
    check not content.contains("Expected script name")
    check not content.contains("script name:")

  test "can access root":
    # If this fails then alltest is likely not running.
    let resp = waitFor client.get(address & "/foo/")
    check resp.status.startsWith("200")
    check (waitFor resp.body) == "Hello World"

  test "/nil":
    # Issue #139
    let resp = waitFor client.get(address & "/foo/nil")
    check resp.status.startsWith("200")
    check (waitFor resp.body) == ""

  test "/halt":
    let resp = waitFor client.get(address & "/foo/halt")
    check resp.status.startsWith("502")
    check (waitFor resp.body) == "I'm sorry, this page has been halted."

  test "/halt-before":
    let resp = waitFor client.request(address & "/foo/halt-before/something", HttpGet)
    let body = waitFor resp.body
    check body == "Halted!"

  test "/guess":
    let resp = waitFor client.get(address & "/foo/guess/foo")
    check (waitFor resp.body) == "Haha. You will never find me!"
    let resp2 = waitFor client.get(address & "/foo/guess/Frank")
    check (waitFor resp2.body) == "You've found me!"

  test "/redirect":
    let resp = waitFor client.request(address & "/foo/redirect/halt", HttpGet)
    check resp.headers["location"] == "http://localhost:5454/foo/halt"

  test "/redirect-halt":
    let resp = waitFor client.request(address & "/foo/redirect-halt/halt", HttpGet)
    check resp.headers["location"] == "http://localhost:5454/foo/halt"
    check (waitFor resp.body) == ""

  test "/redirect-before":
    let resp = waitFor client.request(address & "/foo/redirect-before/anywhere", HttpGet)
    check resp.headers["location"] == "http://localhost:5454/foo/nowhere"
    let body = waitFor resp.body
    check body == ""

  test "regex":
    let resp = waitFor client.get(address & "/foo/02.html")
    check (waitFor resp.body) == "02"

  test "resp":
    let resp = waitFor client.get(address & "/foo/resp")
    check (waitFor resp.body) == "This should be the response"

  test "template":
    let resp = waitFor client.get(address & "/foo/template")
    check (waitFor resp.body) == "Templates now work!"

  test "json":
    let resp = waitFor client.get(address & "/foo/json")
    check resp.headers["Content-Type"] == "application/json"
    check (waitFor resp.body) == """{"name":"Dominik"}"""

  test "sendFile":
    let resp = waitFor client.get(address & "/foo/sendFile")
    check (waitFor resp.body) == "Hello World!"

  test "can access query":
    let resp = waitFor client.get(address & "/foo/query?q=test")
    check (waitFor resp.body) == """{"q": "test"}"""

  test "can access querystring":
    let resp = waitFor client.get(address & "/foo/querystring?q=test&field=5")
    check (waitFor resp.body) == "q=test&field=5"

  test "issue 157":
    let resp = waitFor client.get(address & "/foo/issue157")
    let headers = resp.headers
    check headers["Content-Type"] == "text/css"

  test "resp doesn't overwrite headers":
    let resp = waitFor client.get(address & "/foo/manyheaders")
    let headers = resp.headers
    check headers["foo"] == "foo"
    check headers["bar"] == "bar"
    check headers["Content-Type"] == "text/plain"

  test "redirect set http status code":
    let resp = waitFor client.get(address & "/foo/redirectDefault")
    check resp.code == Http303
    let resp301 = waitFor client.get(address & "/foo/redirect301")
    check resp301.code == Http301
    let resp302 = waitFor client.get(address & "/foo/redirect302")
    check resp302.code == Http302

  suite "static":
    test "index.html":
      let resp = waitFor client.get(address & "/foo/root")
      let body = waitFor resp.body
      check body.startsWith("This should be available at /root/.")

    test "test_file.txt":
      let resp = waitFor client.get(address & "/foo/root/test_file.txt")
      check (waitFor resp.body) == "Hello World!"

    test "detects attempts to read parent dirs":
      # curl -v --path-as-is http://127.0.0.1:5454/foo/../public2/should_be_inaccessible
      let resp = waitFor client.get(address & "/foo/root/../../tester.nim")
      check resp.code == Http400
      let resp2 = waitFor client.get(address & "/foo/root/..%2f../tester.nim")
      check resp2.code == Http400
      let resp3 = waitFor client.get(address & "/foo/../public2/should_be_inaccessible")
      check resp3.code == Http400

  suite "extends":
    test "simple":
      let resp = waitFor client.get(address & "/foo/internal/simple")
      check (waitFor resp.body) == "Works!"

    test "params":
      let resp = waitFor client.get(address & "/foo/internal/params/blah")
      check (waitFor resp.body) == "blah"

    test "separate module":
      let resp = waitFor client.get(address & "/foo/external/params/qwer")
      check (waitFor resp.body) == "qwer"

    test "external regex":
      let resp = waitFor client.get(address & "/foo/external/(foobar)/qwer/")
      check (waitFor resp.body) == "qwer"

    test "regex path prefix escaped":
      let resp = waitFor client.get(address & "/foo/(regexEscaped.txt)/(foobar)/1/")
      check (waitFor resp.body) == "1"

  suite "error":
    test "exception":
      let resp = waitFor client.get(address & "/foo/MyCustomError")
      check (waitFor resp.body) == "Something went wrong: ref MyCustomError"

    test "HttpCode handling":
      let resp = waitFor client.get(address & "/foo/403")
      check (waitFor resp.body) == "OK: 403 Forbidden"

    test "`pass` in error handler":
      let resp = waitFor client.get(address & "/foo/401")
      check (waitFor resp.body) == "OK: 401 Unauthorized"

    test "custom 404":
      let resp = waitFor client.get(address & "/foo/404")
      check (waitFor resp.body) == "404 not found!!!"

  suite "before/after":
    test "before - halt":
      let resp = waitFor client.get(address & "/foo/before/restricted")
      check (waitFor resp.body) == "You cannot access this!"

    test "before - unaffected":
      let resp = waitFor client.get(address & "/foo/before/available")
      check (waitFor resp.body) == "This is accessible"

    test "before - global":
      let resp = waitFor client.get(address & "/foo/before/global")
      check (waitFor resp.body) == "Before/Global: OK! After global `before`: OK!"

    test "before - 404":
      let resp = waitFor client.get(address & "/foo/before/blah")
      check resp.code == Http404

    test "after - added":
      let resp = waitFor client.get(address & "/foo/after/added")
      check (waitFor resp.body) == "Hello! Added by after!"

proc issue150() =
  startServer("issue150.nim")
  var client = newAsyncHttpClient(maxRedirects = 0)

  suite "issue150":
    test "can get root":
      # If this fails then `issue150` is likely not running.
      let resp = waitFor client.get(address)
      check resp.code == Http200

    test "can use custom 404 handler":
      let resp = waitFor client.get(address & "/nonexistent")
      check resp.code == Http404
      check (waitFor resp.body) == "Looks you took a wrong turn somewhere."

    test "can use custom error handler":
      let resp = waitFor client.get(address & "/raise")
      check resp.code == Http500
      check (waitFor resp.body).startsWith("Something bad happened")

proc customRouterTest() =
  startServer("customRouter.nim")
  var client = newAsyncHttpClient(maxRedirects = 0)

  suite "customRouter":
    test "error handler":
      let resp = waitFor client.get(address & "/raise")
      check resp.code == Http500
      let body = (waitFor resp.body)
      checkpoint body
      check body.startsWith("Something bad happened: Foobar")

    test "redirect in error":
      let resp = waitFor client.get(address & "/definitely404route")
      check resp.code == Http303
      check resp.headers["location"] == address & "/404"
      check (waitFor resp.body) == ""

proc issue247() =
  startServer("issue247.nim")
  var client = newAsyncHttpClient(maxRedirects = 0)

  suite "issue247":
    test "duplicate keys in query":
      let resp = waitFor client.get(address & "/multi?a=1&a=2")
      check (waitFor resp.body) == "a: 1,2"

    test "no duplicate keys in query":
      let resp = waitFor client.get(address & "/multi?a=1")
      check (waitFor resp.body) == "a: 1"

    test "assure that empty values are handled":
      let resp = waitFor client.get(address & "/multi?a=1&a=")
      check (waitFor resp.body) == "a: 1,"

    test "assure that fragment is not parsed":
      let resp = waitFor client.get(address & "/multi?a=1&#a=2")
      check (waitFor resp.body) == "a: 1"

    test "ensure that values are url decoded per default":
      let resp = waitFor client.get(address & "/multi?a=1&a=1%232")
      check (waitFor resp.body) == "a: 1,1#2"

    test "ensure that keys are url decoded per default":
      let resp = waitFor client.get(address & "/multi?a%23b=1&a%23b=1%232")
      check (waitFor resp.body) == "a#b: 1,1#2"

    test "test different keys":
      let resp = waitFor client.get(address & "/multi?a=1&b=2")
      check (waitFor resp.body) == "a: 1b: 2"

    test "ensure that path params aren't escaped":
      let resp = waitFor client.get(address & "/hello%23world")
      check (waitFor resp.body) == "val%23ue: hello%23world"

    test "test path params and query":
      let resp = waitFor client.get(address & "/hello%23world?a%23+b=1%23+b")
      check (waitFor resp.body) == "a# b: 1# bval%23ue: hello%23world"

    test "test percent encoded path param and query param (same key)":
      let resp = waitFor client.get(address & "/hello%23world?val%23ue=1%23+b")
      check (waitFor resp.body) == "val#ue: 1# bval%23ue: hello%23world"

    test "test path param, query param and x-www-form-urlencoded":
      client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
      let resp = waitFor client.post(address & "/hello%23world?val%23ue=1%23+b", "val%23ue=1%23+b&b=2")
      check (waitFor resp.body) == "b: 2val#ue: 1# b,1# bval%23ue: hello%23world"

    test "params duplicate keys in query":
      let resp = waitFor client.get(address & "/params?a=1&a=2")
      check (waitFor resp.body) == "a: 2"

    test "params no duplicate keys in query":
      let resp = waitFor client.get(address & "/params?a=1")
      check (waitFor resp.body) == "a: 1"

    test "params assure that empty values are handled":
      let resp = waitFor client.get(address & "/params?a=1&a=")
      check (waitFor resp.body) == "a: "

    test "params assure that fragment is not parsed":
      let resp = waitFor client.get(address & "/params?a=1&#a=2")
      check (waitFor resp.body) == "a: 1"

    test "params ensure that values are url decoded per default":
      let resp = waitFor client.get(address & "/params?a=1&a=1%232")
      check (waitFor resp.body) == "a: 1#2"

    test "params ensure that keys are url decoded per default":
      let resp = waitFor client.get(address & "/params?a%23b=1&a%23b=1%232")
      check (waitFor resp.body) == "a#b: 1#2"

    test "params test different keys":
      let resp = waitFor client.get(address & "/params?a=1&b=2")
      check (waitFor resp.body) == "a: 1b: 2"

    test "params ensure that path params aren't escaped":
      let resp = waitFor client.get(address & "/params/hello%23world")
      check (waitFor resp.body) == "val%23ue: hello%23world"

    test "params test path params and query":
      let resp = waitFor client.get(address & "/params/hello%23world?a%23+b=1%23+b")
      check (waitFor resp.body) == "a# b: 1# bval%23ue: hello%23world"

    test "params test percent encoded path param and query param (same key)":
      let resp = waitFor client.get(address & "/params/hello%23world?val%23ue=1%23+b")
      check (waitFor resp.body) == "val#ue: 1# bval%23ue: hello%23world"

    test "params test path param, query param and x-www-form-urlencoded":
      client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
      let resp = waitFor client.post(address & "/params/hello%23world?val%23ue=1%23+b", "val%23ue=1%23+b&b=2")
      check (waitFor resp.body) == "b: 2val#ue: 1# bval%23ue: hello%23world"

when isMainModule:
  try:
    allTest()
    issue150()
    customRouterTest()
    issue247()
  finally:
    stopServer()
