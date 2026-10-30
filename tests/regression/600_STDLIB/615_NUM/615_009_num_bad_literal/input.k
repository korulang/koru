// std/num: malformed literal is a lawful |bad branch carrying the
// offending slice — not a crash.
import std/io
import std/num

std/num:lit(s: "abc")
| exact a |> std/io:print.ln("parsed") |> std/num:free(n: a)
| bad x |> std/io:print.ln("bad: {{ x:s }}")
