# JS-04: Connection token matching without allocating substring sequences.
import jestersimple/private/httptransport

# ------------------------------------------------------------------------------
# API: Exercise whole-token matching, whitespace, case and substring traps.
# ------------------------------------------------------------------------------
proc checkTokens() =
  doAssert hasConnectionToken("upgrade", "upgrade")
  doAssert hasConnectionToken("Upgrade", "upgrade")
  doAssert hasConnectionToken("Keep-Alive, UpGrAdE", "UPGRADE")
  doAssert hasConnectionToken("keep-alive,\tUPGRADE \t, close", "upgrade")
  doAssert hasConnectionToken("close, keep-alive", "close")
  doAssert hasConnectionToken(" , ,close,,", "close")
  doAssert not hasConnectionToken("", "upgrade")
  doAssert not hasConnectionToken("upgrade", "")
  doAssert not hasConnectionToken("xupgrade", "upgrade")
  doAssert not hasConnectionToken("upgradeX", "upgrade")
  doAssert not hasConnectionToken("not-upgrade, close", "upgrade")
  doAssert not hasConnectionToken("upgradeable", "upgrade")
  doAssert not hasConnectionToken("upgrade;close", "upgrade")
  doAssert not hasConnectionToken("keep-alive", "close")

when isMainModule:
  checkTokens()
  echo "JS-04 Connection token unit tests PASS"
