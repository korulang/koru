// replace, empty-match edge: `a*` matches the empty string at every
// position — the guard steps one byte and the byte stays in the literal
// run, so X lands between every character.
import std/io
import std/regex

std/regex:replace(input: "xyz", with: "X")
| `a*` r |> std/io:print.ln("{{ r:s }}")
