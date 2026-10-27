# Copyright (C) 2012 Dominik Picheta
# MIT License - Look at license.txt for details.
import htmlgen

# ------------------------------------------------------------------------------
# Escape all variable text: htmlgen inserts string arguments as raw HTML.
# ------------------------------------------------------------------------------
func escapeHtml(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    of '\'': result.add("&#39;")
    else: result.add(c)

# ------------------------------------------------------------------------------
# Construct default status pages without interpreting caller input as markup.
# ------------------------------------------------------------------------------
func error*(err, jesterVer: string): string =
  let status = escapeHtml(err)
  return html(head(title(status)),
              body(h1(status),
                   "<hr/>",
                   p("Jester " & escapeHtml(jesterVer)),
                   style = "text-align: center;"),
              xmlns = "http://www.w3.org/1999/xhtml")

# ------------------------------------------------------------------------------
# Preserve this helper's API, but always escape its detail argument.
# Production error handling does not pass private exception details here.
# ------------------------------------------------------------------------------
func routeException*(detail, jesterVer: string): string =
  return html(head(title("Jester route exception")),
              body(h1("An error occurred in one of your routes."),
                   p(b("Detail: "), escapeHtml(detail)),
                   p("Jester " & escapeHtml(jesterVer))),
              xmlns = "http://www.w3.org/1999/xhtml")
