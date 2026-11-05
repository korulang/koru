// replace, \{name} backref: the named-group spelling of the same expansion.
import std/io
import std/regex

std/regex:replace(input: "one two", with: "[\{w}]")
| `(?<w>[a-z]+)` r |> std/io:print.ln("{{ r:s }}")
