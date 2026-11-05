// replace, no refs: every digit run swaps for the literal template.
import std/io
import std/regex

std/regex:replace(input: "a12b345c", with: "X")
| `[0-9]+` r |> std/io:print.ln("{{ r:s }}")
