// PIN (collapse-recursion pass, WAY-TWO leg — BOUNDARY PROBE): n=92 is the
// last i64-exact Fibonacci (7540113804746346429). Fast-doubling would compute
// fib(93) and overflow where the original recursion does not, so the emitted
// body must carry the literal boundary answer for n == 92 and reserve the
// closed form for n <= 91. This pins exactness at the proven boundary —
// not assumed.
import std/io

pub tor fib { n: i64 } -> i64

fib = if(n < 2)
| then -> n
| else |> fib(n: n - 1): a |> fib(n: n - 2): b -> a + b

fib(n: 92): r |> std/io:print.ln("{{ r:d }}")
