// PIN (collapse-recursion pass, WAY-TWO leg): loop-k's accumulator
// (@rem(acc + i*j*k, P), k decreasing, i/j threaded) admits R2a — the
// additive Faulhaber sum under modulus in i128 with exact checked fallback.
// Multi-param coeff (i*j) exercises the coeff-guard spine. Kebab name
// loop-k must residual-spell loop_k_event. Sum_{j=1..4} 2*3*j = 60.
import std/io

pub tor loop-k { i: i64, j: i64, k: i64, acc: i64 } -> i64

loop-k = if(k == 0)
| then -> acc
| else |> loop-k(i, j, k: k - 1, acc: @rem(acc + i * j * k, 1000000007)): v -> v

loop-k(i: 2, j: 3, k: 4, acc: 0): r |> std/io:print.ln("{{ r:d }}")
