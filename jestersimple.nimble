# Jester Simple package metadata; keep version in sync with jestersimple.nim.
version       = "1.0.0"
author        = "Dominik Picheta and contributors"
description   = "Lightweight, security-hardened Nim HTTP framework for embedded Linux."
license       = "MIT"

# Exclude test sources from an installed Nimble package.
skipDirs = @["tests"]

requires "nim >= 2.2.12"

task test, "Run Linux core integration tests (stdlib only).":
  exec "nim c -r --mm:orc --hints:off --path:. tests/tester.nim"
