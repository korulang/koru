// STRICT 1:1, the discard side: a pattern that declares named groups but
// discards the payload asked for captures it never takes delivery of.
// The discard form lives in the PATTERN — spell unwanted captures `(...)`.
import std/io
import std/regex

std/regex:match("42")
| `(?<x>[0-9]+)` _ |> std/io:print.ln("num")
| no-match |> std/io:print.ln("no")
