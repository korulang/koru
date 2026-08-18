// PIN (2026-07-03): the multi-arg / non-swap generalization of 320_121. A tail
// self-loop whose LATER-declared field's update reads an EARLIER field that was
// already reassigned. Here `loop-k`'s reentry sets k=k-1 then acc=acc+i*j*k, and
// acc's RHS must read the OLD k. Sequential emission (before the emitSelfTailReentry
// snapshot fix) read the decremented k. Unlike 320_121's gcd, the corrupted field
// (k) is not part of a swap — just an earlier sibling. loop-k(2,3,4,0) = 60 (naive:
// acc += i*j*k for k=4,3,2,1 = 2*3*(4+3+2+1)); the bug emitted 36.
// Surfaced by the koru-benchmarks `nestedloop` kernel (challenge 004).
import std/io

pub tor loop-k { i: i64, j: i64, k: i64, acc: i64 } -> i64

loop-k = if(k == 0)
| then -> acc
| else |> loop-k(i, j, k: k - 1, acc: acc + i * j * k): v -> v

loop-k(i: 2, j: 3, k: 4, acc: 0): r |> std/io:print.ln("{{ r:d }}")
