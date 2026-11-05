// replace, no match: the input passes through untouched.
import std/io
import std/regex

std/regex:replace(input: "no digits", with: "X")
| `[0-9]+` r |> std/io:print.ln("{{ r:s }}")
