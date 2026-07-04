// PIN (2026-07-04, positive): the multi-bind produce — a bare-return produce
// expression that reads an EARLIER bind alongside the latest one:
//     fib(n: n - 1): a |> fib(n: n - 2): b -> a + b
// This is non-tail TREE recursion (two recursive calls whose results
// combine), the shape the koru-benchmarks fib/hanoi/tak kernels stand on.
// The corpus previously proved produces reading (event arg + latest bind)
// (digitsum shape) and later CALLS reading earlier binds (nestedloop shape),
// but never a produce reading TWO binds. Surfaced green by the fib kernel
// (fib(35) = 9227465 through koruc); pinned here minimal as fib(10) = 55.
import std/io

pub event fib { n: i64 } -> i64

fib = if(n < 2)
| then -> n
| else |> fib(n: n - 1): a |> fib(n: n - 2): b -> a + b

fib(n: 10): r |> std/io:print.ln("{{ r:d }}")
