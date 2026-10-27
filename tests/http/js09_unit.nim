# JS-09: resolver-only checks; automatic static lookup is distinct from sendFile.
import std/[httpcore, os, unittest]
import jestersimple/private/staticfiles

let root = getEnv("JS09_STATIC_ROOT")
let explicitFile = getEnv("JS09_EXPLICIT_FILE")

# ------------------------------------------------------------------------------
# Obtain status without leaving a pinned file descriptor open.
# ------------------------------------------------------------------------------
proc staticStatus(path: string): HttpCode =
  var asset = openConfinedStatic(root, path)
  result = asset.status
  closeStatic(asset)

suite "automatic static URL visibility":
  test "reject hidden files and directories at any depth":
    for path in ["/.env", "/.git/config", "/sub/.config",
                 "/.well-known/acme.txt", "/sub/.git/config"]:
      check staticStatus(path) == Http404

  test "percent-encoded leading dots are equally hidden":
    for path in ["/%2eenv", "/.%65nv", "/%2Egit/config",
                 "/sub/%2econfig", "/%2ewell-known/acme.txt"]:
      check staticStatus(path) == Http404

  test "public files remain accessible":
    for path in ["/index.html", "/sub/visible.txt", "/sub/data.bak",
                 "/%252eenv"]:
      check staticStatus(path) == Http200

  test "malformed dot segments retain their existing rejection":
    for path in ["/.", "/..", "/sub/%2e%2e/secret"]:
      check staticStatus(path) == Http400

suite "explicit application-selected file":
  test "sendFile resolver may open an outside dotfile":
    var asset = openExplicitStatic(explicitFile)
    try:
      check asset.status == Http200
      if asset.status == Http200:
        let content = readStaticExactly(asset.fd, int(asset.size))
        check content == "JS09-EXPLICIT-PRIVATE-CONTENT"
    finally:
      closeStatic(asset)
