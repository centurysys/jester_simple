# JS-10: compile-time router integration, including intentionally invalid cases.
import jestersimple

when defined(js10InvalidLeadingOptional):
  router js10Invalid:
    get "?":
      resp "unreachable"
elif defined(js10InvalidTrailingEscape):
  router js10Invalid:
    get "/bad\\":
      resp "unreachable"
else:
  router js10Valid:
    get "/optional.?":
      resp "optional"
    get "/items/@id?":
      resp "item"
