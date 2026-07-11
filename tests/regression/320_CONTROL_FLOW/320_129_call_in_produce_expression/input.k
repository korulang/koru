// PIN (2026-07-05): a call inside a PRODUCE (->) expression is ILLEGAL —
// calls are not expressions (see concepts/frag-arguments-are-atoms). The
// idiom is bind-first:
//     g(a: 4): x -> 1 + x
//
// Guarded by the KORU104 expression-admission wall (flow_checker, Stage A).
// Bare-return impls parse as `immediate_impl` items with the produce text
// in plain_value — the wall walks those items explicitly. Before the wall:
// `return 1 + g(a: 4);` pasted verbatim into emitted Zig, raw Stage-D error.
import std/io

pub event g { a: i64 } -> i64
g -> a + 1

pub event outer {} -> i64
outer -> 1 + g(a: 4)

outer(): v |> std/io:print.ln("{{ v:d }}")
