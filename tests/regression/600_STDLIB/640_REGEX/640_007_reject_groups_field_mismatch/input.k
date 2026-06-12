// STRICT 1:1 (Lars-ratified 2026-06-12): destructure fields ↔ named groups
// must match BOTH ways, compile-time error from the transform (it owns
// pattern AND destructure at the same site). Here group `w` is captured
// but never destructured — unwanted capture must be spelled `(...)`.
import std/io
import std/regex

std/regex:match("2x3")
| `(?<l>[0-9]+)x(?<w>[0-9]+)` { l: i64 } |> std/io:print.ln("{{ l:d }}")
| no-match |> std/io:print.ln("no")
