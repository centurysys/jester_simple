# Step 11: isolated multipart parser unit tests; no HTTP server needed.
import std/[unittest, strutils, tables, strtabs, sequtils]
import jestersimple/private/multipart

proc part(name, value: string, filename = ""): string =
  result = "Content-Disposition: form-data; name=\"" & name & "\""
  if filename.len != 0:
    result.add "; filename=\"" & filename & "\""
  result.add "\r\n\r\n" & value

proc envelope(boundary: string, fragments: seq[string]): string =
  for fragment in fragments:
    result.add "--" & boundary & "\r\n" & fragment & "\r\n"
  result.add "--" & boundary & "--\r\n"

suite "Step 11 multipart parser":
  test "normal parts and metadata":
    let fields = parseMPFD("multipart/form-data; boundary=ABC",
      envelope("ABC", @[part("text", "hello"), part("file", "data", "a.txt")]))
    check fields.len == 2
    check fields["text"].body == "hello"
    check fields["file"].body == "data"
    check fields["file"].fields["filename"] == "a.txt"
    check fields["file"].fields["content-disposition"].startsWith("form-data")

  test "quoted boundary and case insensitive media type":
    let fields = parseMPFD("MULTIPART/FORM-DATA; charset=UTF-8; BOUNDARY=\"x:y?z\"",
      envelope("x:y?z", @[part("x", "yes")]))
    check fields["x"].body == "yes"

  test "filename with escaped quote and backslash":
    let body = "--abc\r\nContent-Disposition: form-data; name=\"f\"; " &
      "filename=\"a\\\"b\\\\c.txt\"\r\n\r\nhello\r\n--abc--\r\n"
    let fields = parseMPFD("multipart/form-data; boundary=abc", body)
    check fields["f"].fields["filename"] == "a\"b\\c.txt"

  test "binary data and boundary-like bytes remain intact":
    let binary = "abc\0\r\n--Xfake\r\nnext\255"
    let fields = parseMultiPart(envelope("X", @[part("f", binary)]), "X")
    check fields["f"].body == binary

  test "duplicate field names preserve last-wins compatibility":
    let fields = parseMPFD("multipart/form-data; boundary=x",
      envelope("x", @[part("v", "first"), part("v", "second")]))
    check fields.len == 1
    check fields["v"].body == "second"

  test "empty multipart, preamble and epilogue":
    check parseMultiPart("--abc--\r\n", "abc").len == 0
    let data = "preamble\r\n" & envelope("abc", @[part("q", "ok")]) &
      "epilogue"
    check parseMultiPart(data, "abc")["q"].body == "ok"

  test "missing and duplicate boundary parameters":
    for ct in ["multipart/form-data", "multipart/form-data; boundary=",
               "multipart/form-data; boundary=a; BOUNDARY=b",
               "multipart/form-data; boundary=\"unterminated",
               "multipart/form-dataevil; boundary=a"]:
      expect(ValueError):
        discard parseMPFD(ct, "--a--\r\n")

  test "invalid boundary characters and lengths":
    for boundary in ["", "a b ", "a;bad", "a\0b", repeat("a", 71)]:
      expect(ValueError):
        discard parseMultiPart("--" & boundary & "--\r\n", boundary)

  test "truncated body and missing closing delimiter":
    for body in ["", "--x", "--x\r\n", "--x\r\n" & part("a", "b"),
                 "--x\r\n" & part("a", "b") & "\r\n--x-",
                 "--x\r\n" & part("a", "b") & "\r\n--x--BAD"]:
      expect(ValueError):
        discard parseMultiPart(body, "x")

  test "invalid part headers and missing name":
    for headers in ["X-Bad\r\n", " Content-Disposition: form-data; name=x\r\n",
                    "Content-Disposition: form-data\r\n",
                    "Content-Disposition: attachment; name=x\r\n",
                    "Content-Disposition: form-data; name=x; name=y\r\n",
                    "Content-Disposition: form-data; name=x\r\n" &
                    "Content-Disposition: form-data; name=y\r\n"]:
      expect(ValueError):
        discard parseMultiPart("--x\r\n" & headers &
          "\r\nbody\r\n--x--\r\n", "x")

  test "part header size and count caps":
    expect(ValueError):
      discard parseMultiPart("--x\r\nContent-Disposition: form-data; name=x\r\n" &
        "X-Long: " & repeat("a", 8200) & "\r\n\r\ny\r\n--x--\r\n", "x")
    let many = repeat("X-Test: x\r\n", 65)
    expect(ValueError):
      discard parseMultiPart("--x\r\nContent-Disposition: form-data; name=x\r\n" &
        many & "\r\ny\r\n--x--\r\n", "x")

  test "part count limit":
    let fragments = newSeqWith(129, part("x", "value"))
    expect(ValueError):
      discard parseMultiPart(envelope("x", fragments), "x")

  test "media type recognition is exact":
    check isMultipartForm("MULTIPART/FORM-DATA; boundary=x")
    check not isMultipartForm("multipart/form-data-evil; boundary=x")
    check not isMultipartForm("application/x-www-form-urlencoded")
