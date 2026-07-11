// MUST_FAIL — firing a value-resuming OPTIONAL arm WITHOUT a presence test.
// Designed 2026-07-03: `! ?ask i64 -> i64` may be omitted by the consumer,
// so an UNGUARDED fire binds a value that might not exist. No no-op can be
// synthesized (a fn with a mandatory return and an empty body is not a
// thing), and a fabricated default would be a silent fallback. The wall:
// the fire must be dominated by a presence test (`if(ask)` / `when ask`,
// 400_146/147), and the diagnostic points there — pit-of-success.
//
// Pinned failure BEFORE the wall existed: this exact program sailed through
// analysis and died at Stage D with a raw Zig leak ("function with non-void
// return type 'i64' implicitly returns" on the synthesized no-op).
import std/io

pub event query { q: i64 }
! ?ask i64 -> i64
| done i64

query = ask(q): a => done a

query(q: 41)
| done r |> std/io:print.ln("{{ r:d }}")
