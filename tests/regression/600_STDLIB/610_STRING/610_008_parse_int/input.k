// Test: parse a string's text to an integer (FRONTIERS gap 4 — safe op).
// parse-int returns a scalar i64; a scalar owns itself, so the ratified
// "terminal payloads must own" rule holds with zero borrow machinery.
import std/string
import std/io

std/string:from-page(text: "42")
| ok s |> std/string:parse-int(s)
    | ok n  |> std/io:print.ln("{{ n:d }}") |> std/string:free(s)
    | err e |> std/io:print.ln("{{ e:s }}") |> std/string:free(s)
| err _ |> _
