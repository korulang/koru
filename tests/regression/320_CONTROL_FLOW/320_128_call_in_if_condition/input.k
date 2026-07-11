// PIN (2026-07-05): a call inside an if CONDITION expression is ILLEGAL —
// calls are not expressions (see concepts/frag-arguments-are-atoms). The
// idiom is bind-first:
//     g(a: 4): x |> if(x > 3) ...
//
// Guarded by the KORU104 expression-admission wall (flow_checker, Stage A);
// if-conditions parse as invocation arguments, so the argument walk covers
// them. Before the wall: `if (g(a: 4) > 3)` pasted verbatim into emitted
// Zig, raw Stage-D host error.
import std/io

pub event g { a: i64 } -> i64
g -> a + 1

pub event pick {} -> i64
pick = if(g(a: 4) > 3)
| then -> 1
| else -> 2

pick(): v |> std/io:print.ln("{{ v:d }}")
