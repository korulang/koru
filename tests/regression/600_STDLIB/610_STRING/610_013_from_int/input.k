// Test: from-int — build a NEW owned String<view!> from an integer (FRONTIERS
// gap 4, the int→string mirror of parse-int). Owned return, no borrow.
import std/string
import std/io

std/string:from-int(n: 42)
| ok s |> std/io:print.ln("{{ s:S }}") |> std/string:free(s)
| err _ |> _
