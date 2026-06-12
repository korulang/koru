// Named-group captures (FRONTIERS §1, design ratified 2026-06-12): the
// pattern is the branch's PAYLOAD SCHEMA. Named groups deliver through the
// landed shape-destructure at the binding position; a TYPE on a field is
// CONVERSION here (text→int dissolves at the splice — the `0[i32]` move),
// not just an assertion. Bare `(...)` stays non-capturing structure.
// The day-2 dims flagship: three numbers out of `LxWxH`.
import std/io
import std/regex

std/regex:match("2x3x4")
| `(?<l>[0-9]+)x(?<w>[0-9]+)x(?<h>[0-9]+)` { l: i64, w: i64, h: i64 } |> std/io:print.ln("{{ l:d }} {{ w:d }} {{ h:d }}")
| no-match |> std/io:print.ln("no")
