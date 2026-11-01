// std/num: scientific notation parses to canonical form.
import std/io
import std/num

std/num:lit { 6.022e23 }
| exact a |> std/io:print.ln("{{ a:s }}") |> std/num:free(n: a)
| bad x |> std/io:print.ln("bad")
