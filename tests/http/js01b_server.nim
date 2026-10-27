# JS-01b: route extension with and without path prefixes.
import std/[net, os, strutils]
import jestersimple

settings:
  port = Port(parseInt(getEnv("JS01B_PORT", "5531")))
  bindAddr = "127.0.0.1"

# ------------------------------------------------------------------------------
# Each source route uses a distinct path to make prefix behavior observable.
# ------------------------------------------------------------------------------
router implicitSource:
  get "/implicit":
    resp "implicit-ok"

router emptySource:
  get "/empty":
    resp "empty-ok"

router prefixSource:
  get "/item":
    resp "prefix-ok"

# ------------------------------------------------------------------------------
# Verify implicit, explicit-empty, and nonempty prefixes at the same level.
# ------------------------------------------------------------------------------
router composedRoutes:
  extend implicitSource
  extend emptySource, ""
  extend prefixSource, "/v1"
  extend prefixSource, "/v2"

# ------------------------------------------------------------------------------
# Verify that omission also works when an extended router is extended again.
# ------------------------------------------------------------------------------
router nestedRoutes:
  extend composedRoutes
  extend prefixSource, "/v3"

when defined(js01bAsync):
  router asyncRoutes:
    {.async.}
    extend nestedRoutes

  var app = initJester(asyncRoutes, settings)
elif defined(js01bMulti):
  router unrelatedRoutes:
    get "/unrelated":
      resp "unrelated-ok"

  var app = initJester(nestedRoutes, settings)
  app.register(unrelatedRoutes.matcher)
  app.register(unrelatedRoutes.errorHandler)
else:
  var app = initJester(nestedRoutes, settings)

serve(app)
