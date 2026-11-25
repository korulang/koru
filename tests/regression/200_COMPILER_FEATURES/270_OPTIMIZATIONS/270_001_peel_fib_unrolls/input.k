// PIN (recursion-unroll pass, challenge 035 leg): the peel/unroll pass must
// fire on the fib shape — direct self-recursion, one param decreasing by a
// constant on every self-call site, pure scalar body. At the pinned default
// depth D=2 with s=2 self-call sites the emitted Zig must carry
// s^(D+1) = 8 residual `fib_event.handler(` self-calls inside the impl plus
// the one external call in the main flow (9 total), and parameter-substituted
// guards (`n - 1` inside the `< 2` test — the original body only ever compares
// bare `n`). expected.txt proves the transform preserves semantics.
// RED until the pass lands; post.sh is the contract.
import std/io

pub tor fib { n: i64 } -> i64

fib = if(n < 2)
| then -> n
| else |> fib(n: n - 1): a |> fib(n: n - 2): b -> a + b

fib(n: 10): r |> std/io:print.ln("{{ r:d }}")
