// PIN (recursion-unroll pass, challenge 035 leg): recursion with no
// designated decreasing parameter must REFUSE — silently, unchanged. Each
// self-call site decrements a DIFFERENT param (`n` on site A, `k` on site
// B); no single param decreases on every site, so the termination witness
// fails even though the program terminates (nested-if bases cover both
// params). Baseline: 3 `fnd_event.handler(` sites (2 self + 1 main), no
// substituted guards, correct output. This is the pure-shape refusal — no
// effects involved.
import std/io

pub tor fnd { n: i64, k: i64 } -> i64

fnd = if(n < 2)
| then -> k
| else |> if(k < 0)
    | then -> 0
    | else |> fnd(n: n - 1, k): a |> fnd(n, k: k - 1): b -> a + b

fnd(n: 4, k: 3): r |> std/io:print.ln("{{ r:d }}")
