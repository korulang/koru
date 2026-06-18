// PINNED GAP (currently RED) — the global/streaming regex `scan`: arity scaling
// done right. `match` finds ONE whole-input match (anchored); `scan` would find
// EVERY non-overlapping occurrence as an effect stream, reusing the same
// named-group destructure per hit — `!` (each) where match uses `|` (once).
// Variable arity lives in the stream's cardinality, fixed captures per match, so
// it respects the groups-under-quantifier doctrine (640_008). Blocked on the
// regex engine's unanchored-search "later cut" (src/regex_engine.zig:425 — the
// matchers are whole-string-anchored). The naive-phase stand-in is std/string:
// split + anchored match per piece. Greening this is the regex-engine investment.
import std/io
import std/regex

std/regex:scan(input: "a: 1, bb: 22, c: 3")
! `(?<k>[a-z]+): (?<n>[0-9]+)` { k: []const u8, n: i64 } |> std/io:print.ln("{{ k:s }}={{ n:d }}")
| done _ |> std/io:print.ln("done")
