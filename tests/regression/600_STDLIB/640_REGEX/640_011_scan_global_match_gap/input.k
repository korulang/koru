// SCAN — the global/streaming regex: `!` (each) where match uses `|` (once).
// `match` finds ONE whole-input match (anchored); `scan` finds EVERY
// non-overlapping occurrence as an effect stream, firing its `!` pattern branch
// per hit with the same named-group destructure, then runs `| done` once.
// Variable arity lives in the stream's cardinality, fixed captures per match, so
// it respects the groups-under-quantifier doctrine (640_008). Built on the
// engine's leftmost-longest unanchored search (regex_engine.searchLongestFrom /
// compileSearchToZig); captures per span come from the same matcher `match` uses.
// `| done` is void (like match's `no-match`) — bare, no binding.
import std/io
import std/regex

std/regex:scan(input: "a: 1, bb: 22, c: 3")
! `(?<k>[a-z]+): (?<n>[0-9]+)` { k: string, n: i64 } |> std/io:print.ln("{{ k:s }}={{ n:d }}")
| done |> std/io:print.ln("done")
