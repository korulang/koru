// PIN (2026-07-05, honest red): a call inside a CAPTURED field expression
// is ILLEGAL — calls are not expressions (core rule; see 320_127 and
// concepts/frag-arguments-are-atoms). The idiom is bind-first:
//     g(a: i): x |> captured { acc: s.acc + x }
// (exactly how every green kernel folds — collatz, gcdsum). Note the
// branch-constructor purity guard (PARSE003) does NOT cover captured
// fields — this pin holds that hole open. Today the compiler accepts the
// shape and pastes the call's Koru syntax verbatim into emitted Zig — raw
// Stage-D host error. Goes green when the expression-admission wall lands.
import std/io

pub event g { a: i64 } -> i64
g -> a + 1

capture { acc: 0[i64] }
! as s |> for(1..4)
    ! each i |> captured { acc: s.acc + g(a: @as(i64, @intCast(i))) }
| captured r |> std/io:print.ln("{{ r.acc:d }}")
