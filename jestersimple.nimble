# Package

version       = "1.0.0" # Be sure to update jester.jesterVer too!
author        = "Dominik Picheta"
description   = "A sinatra-like web framework for Nim."
license       = "MIT"

skipFiles = @["todo.markdown"]
skipDirs = @["tests"]

# Deps

requires "nim >= 2.2.12"

task test, "Run Linux core integration tests (stdlib only).":
  exec "nim c -r --mm:orc --hints:off --path:. tests/tester.nim"
