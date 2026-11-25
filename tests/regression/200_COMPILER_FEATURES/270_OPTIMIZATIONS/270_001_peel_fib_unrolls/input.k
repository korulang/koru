// PIN (collapse-before-unroll ordering, WAY-TWO leg): collapse-recursion
// runs before unroll-recursion in elaborate and admits this shape first —
// the emitted body must carry __koru_collapse_b1_fib and NO __koru_unroll_
// machine. expected.txt proves collapse preserves semantics.
import std/io

pub tor fib { n: i64 } -> i64

fib = if(n < 2)
| then -> n
| else |> fib(n: n - 1): a |> fib(n: n - 2): b -> a + b

fib(n: 10): r |> std/io:print.ln("{{ r:d }}")
