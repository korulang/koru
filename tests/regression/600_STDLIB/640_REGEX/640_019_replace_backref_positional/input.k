// replace, \1 backref: the Nth capture group in open order (every capture
// is a (?<name>…) group here) wraps each hit.
import std/io
import std/regex

std/regex:replace(input: "one two", with: "<\1>")
| `(?<w>[a-z]+)` r |> std/io:print.ln("{{ r:s }}")
