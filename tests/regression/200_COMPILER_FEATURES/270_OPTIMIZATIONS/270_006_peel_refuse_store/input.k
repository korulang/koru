// PIN (recursion-unroll pass, challenge 035 leg): effects-bearing recursion
// must REFUSE — silently, unchanged. The body is the eligible fib shape plus
// a `std/store:stored` write inside the recursive branch — a store/memory
// effect. Unrolling would duplicate the write across substituted body
// copies, so the pass must decline: baseline 3 `fibs_event.handler(` sites,
// no substituted guards, correct output.
import std/io
import std/store

std/store:new(game) { score: 0[i64] }

pub tor fibs { n: i64 } -> i64

fibs = if(n < 2)
| then -> n
| else |> fibs(n: n - 1): a
    |> std/store:stored { game.score: game.score + 1 }
    |> fibs(n: n - 2): b -> a + b

fibs(n: 5): r |> std/io:print.ln("{{ r:d }}")
