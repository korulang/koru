// PIN (2026-07-05, honest red): a call inside a PRODUCE (->) expression is
// ILLEGAL — calls are not expressions (core rule; see 320_127 and
// concepts/frag-arguments-are-atoms). The idiom is bind-first:
//     g(a: 4): x -> 1 + x
// Today the compiler accepts this through Stage A/B and pastes the call's
// Koru syntax verbatim into emitted Zig: `return 1 + g(a: 4);` — raw
// Stage-D host error. Goes green when the expression-admission wall
// rejects it at the koru level with an event-chaining hint.
import std/io

pub event g { a: i64 } -> i64
g -> a + 1

pub event outer {} -> i64
outer -> 1 + g(a: 4)

outer(): v |> std/io:print.ln("{{ v:d }}")
