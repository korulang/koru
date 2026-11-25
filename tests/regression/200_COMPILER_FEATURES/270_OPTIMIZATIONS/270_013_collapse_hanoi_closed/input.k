// PIN (collapse-recursion pass, WAY-TWO leg): the collapse pass must fire on
// the hanoi accumulator shape — guard n==0, two sibling-fed self-calls with
// acc threaded (+0 then +1), produce the second bind. Admitted as R1: the
// emitted body carries the `__koru_collapse_r1` marker, the closed form
// acc + 2^e*B + D*(2^e-1) + K via checked @import("std").math ops, the
// n>0/n<=62 domain guard, and the identity residual for out-of-domain n.
// n=12 -> 2^12-1 = 4095 proves semantics preserved.
import std/io

pub tor hanoi { n: i64, acc: i64 } -> i64

hanoi = if(n == 0)
| then -> acc
| else |> hanoi(n: n - 1, acc): h |> hanoi(n: n - 1, acc: h + 1): v -> v

hanoi(n: 12, acc: 0): r |> std/io:print.ln("{{ r:d }}")
