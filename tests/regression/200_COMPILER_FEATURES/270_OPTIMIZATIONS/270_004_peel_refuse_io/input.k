// PIN (recursion-unroll pass, challenge 035 leg): effects-bearing recursion
// must REFUSE — silently, unchanged. The body is the eligible fib shape plus
// one `std/io:print.ln` console effect inside the recursive branch. Unrolling
// would duplicate/reorder the effect across substituted body copies, so the
// pass's purity/effect gate must decline it: emitted Zig keeps the baseline
// shape — 2 self-call sites + 1 external = 3 `fibio_event.handler(` calls,
// no parameter-substituted guards. expected.txt records the deterministic
// pre-order "d" lines (one per internal node) plus the result.
import std/io

pub tor fibio { n: i64 } -> i64

fibio = if(n < 2)
| then -> n
| else |> std/io:print.ln("d") |> fibio(n: n - 1): a |> fibio(n: n - 2): b -> a + b

fibio(n: 5): r |> std/io:print.ln("{{ r:d }}")
