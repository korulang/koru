// PIN (2026-07-05): a call inside a CAPTURED field expression is ILLEGAL —
// calls are not expressions (see concepts/frag-arguments-are-atoms). The
// idiom is bind-first, exactly how every green benchmark kernel folds:
//     g(a: i): x |> captured { acc: s.acc + x }
//
// Guarded by the KORU104 expression-admission wall (flow_checker, Stage A).
// capture/captured carry their brace payload as a Source-typed arg; the
// wall parses it as a field-expression list and judges each field. Note
// the PARSE003 branch-ctor guard never covered captured fields — this pin
// holds the wall that does. Before: verbatim Koru leak into emitted Zig.
import std/io

pub event g { a: i64 } -> i64
g -> a + 1

capture { acc: 0[i64] }
! as s |> for(1..4)
    ! each i |> captured { acc: s.acc + g(a: @as(i64, @intCast(i))) }
| captured r |> std/io:print.ln("{{ r.acc:d }}")
