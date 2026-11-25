// PIN (recursion-unroll pass, challenge 035 leg): the peel/unroll pass must
// fire on the pascal/binom shape — three-way branch, `n` decreasing by 1 on
// both self-call sites while `k` is unconstrained (k-1 on one site, pun on
// the other). Eligible under the designated-param witness: `n` alone
// decreases on every site. At D=2, s=2 the emitted Zig must carry 8 residual
// `binom_event.handler(` calls + 1 external (9 total) and substituted guards
// (`k - 1` / `n - 1` inside the `== 0` / `== n` tests).
// RED until the pass lands.
import std/io

pub tor binom { n: i64, k: i64 } -> i64

binom = if(k == 0)
| then -> 1
| else |> if(k == n)
    | then -> 1
    | else |> binom(n: n - 1, k: k - 1): a |> binom(n: n - 1, k): b -> a + b

binom(n: 6, k: 3): r |> std/io:print.ln("{{ r:d }}")
