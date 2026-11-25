// PIN (collapse-before-unroll ordering, WAY-TWO leg): collapse-recursion
// runs before unroll-recursion in elaborate and admits this shape first —
// the emitted body must carry __koru_collapse_r1 and NO __koru_unroll_
// machine. expected.txt proves collapse preserves semantics.
import std/io

pub tor hanoi { n: i64, acc: i64 } -> i64

hanoi = if(n == 0)
| then -> acc
| else |> hanoi(n: n - 1, acc): h |> hanoi(n: n - 1, acc: h + 1): v -> v

hanoi(n: 4, acc: 0): r |> std/io:print.ln("{{ r:d }}")
