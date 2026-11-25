// PIN (recursion-unroll pass, challenge 035 leg — CONTROL): mutual
// recursion is excluded — it is not DIRECT self-recursion (is-even calls
// is-odd, is-odd calls is-even; neither calls itself). Measured 0.24 ns/
// call on the kernel — LLVM already collapses the parity chain, so even a
// hypothetical mutual-to-self fusion would chase noise. The pass must
// refuse both bodies: emitted shape stays baseline (whatever the current
// lowering is — this pin asserts the census does not change), no
// substituted guards, correct output.
import std/io

pub tor is-even { n: i64 } -> i64

pub tor is-odd { n: i64 } -> i64

is-even = if(n == 0)
| then -> 1
| else |> is-odd(n: n - 1): v -> v

is-odd = if(n == 0)
| then -> 0
| else |> is-even(n: n - 1): v -> v

is-even(n: 10): r |> std/io:print.ln("{{ r:d }}")
