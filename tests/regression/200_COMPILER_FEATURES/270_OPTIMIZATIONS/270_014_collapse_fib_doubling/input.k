// PIN (collapse-recursion pass, WAY-TWO leg): fib's two-call produce shape
// admits B1 fast-doubling for n <= 91 — O(log n) instead of the exponential
// tree. Marker __koru_collapse_b1_fib, @clz-based bit scan, i64 doubling
// recurrence. n=10 -> 55 proves semantics.
import std/io

pub tor fib { n: i64 } -> i64

fib = if(n < 2)
| then -> n
| else |> fib(n: n - 1): a |> fib(n: n - 2): b -> a + b

fib(n: 10): r |> std/io:print.ln("{{ r:d }}")
