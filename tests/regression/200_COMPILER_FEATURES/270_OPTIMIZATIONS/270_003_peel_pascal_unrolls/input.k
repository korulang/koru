// PIN (collapse-before-unroll ordering, WAY-TWO leg): collapse-recursion
// runs before unroll-recursion in elaborate and admits this shape first —
// the emitted body must carry __koru_collapse_b2_binom and NO __koru_unroll_
// machine. expected.txt proves collapse preserves semantics.
import std/io

pub tor binom { n: i64, k: i64 } -> i64

binom = if(k == 0)
| then -> 1
| else |> if(k == n)
    | then -> 1
    | else |> binom(n: n - 1, k: k - 1): a |> binom(n: n - 1, k): b -> a + b

binom(n: 6, k: 3): r |> std/io:print.ln("{{ r:d }}")
