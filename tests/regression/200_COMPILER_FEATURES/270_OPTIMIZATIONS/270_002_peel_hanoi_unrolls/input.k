// PIN (recursion-unroll pass, challenge 035 leg): the peel/unroll pass must
// fire on the hanoi shape — the nested sibling-fed self-call
// `hanoi(n-1, hanoi(n-1,acc)+1)` that today lowers to the defunctionalized
// segment machine (__koru_seg_eval). `n` decreases by 1 on both self-call
// sites (`acc` is unconstrained — fed by the sibling bind `h + 1`), so the
// designated-param witness holds and the pass must rewrite the impl to the
// unrolled machine: 8 residual `hanoi_event.handler(` calls + 1 external at
// D=2, with substituted `n - 1` guards. This pins that unrolling composes
// with — or replaces — continuation lowering for the dependent-arg shape,
// not that it bypasses it silently: the site census is the contract.
// RED until the pass lands.
import std/io

pub tor hanoi { n: i64, acc: i64 } -> i64

hanoi = if(n == 0)
| then -> acc
| else |> hanoi(n: n - 1, acc): h |> hanoi(n: n - 1, acc: h + 1): v -> v

hanoi(n: 4, acc: 0): r |> std/io:print.ln("{{ r:d }}")
