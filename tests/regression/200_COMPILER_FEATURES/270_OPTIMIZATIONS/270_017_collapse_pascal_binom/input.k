// PIN (collapse-recursion pass, WAY-TWO leg): binom's double self-call with
// n-1 on both calls and k/k-1 split admits B2 — factorial-quotient product
// for 0 <= k <= n, residual otherwise. C(10,5) = 252 proves semantics.
import std/io

pub tor binom { n: i64, k: i64 } -> i64

binom = if(k == 0)
| then -> 1
| else |> if(k == n)
    | then -> 1
    | else |> binom(n: n - 1, k: k - 1): a |> binom(n: n - 1, k): b -> a + b

binom(n: 10, k: 5): r |> std/io:print.ln("{{ r:d }}")
