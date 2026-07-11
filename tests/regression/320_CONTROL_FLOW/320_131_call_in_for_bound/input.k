// PIN (2026-07-05): a call inside a FOR range-bound expression is ILLEGAL —
// calls are not expressions (see concepts/frag-arguments-are-atoms). The
// idiom is bind-first:
//     g(a: 4): n |> for(1..n) ...
//
// Guarded by the KORU104 expression-admission wall (flow_checker, Stage A);
// for-bounds parse as invocation arguments, so the argument walk covers
// them. Before the wall: `for (1..g(a: 4))` pasted verbatim into emitted
// Zig, raw Stage-D host error.
import std/io

pub event g { a: i64 } -> i64
g -> a + 1

capture { acc: 0[i64] }
! as s |> for(1..g(a: 4))
    ! each i |> captured { acc: s.acc + @as(i64, @intCast(i)) }
| captured r |> std/io:print.ln("{{ r.acc:d }}")
