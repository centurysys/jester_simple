# This module is loaded for the compile-time router registration side effect.
# Suppress only the unused-import diagnostic for this module's importers.
{.used.}

import re

import jestersimple

router external:
  get "/simple":
    resp "Works!"

  get "/params/@foo":
    resp @"foo"

  get re"/\(foobar\)/(.+)/":
    resp request.matches[0]