// PINS: a capture-cell read inside a call ARGUMENT within a `for ! each`
// body sees the LIVE accumulated value — the invariant-prefix hoist must
// not lift a step whose args read a cell the body writes per iteration.
//
//   bump(x: g.n): r |> captured { n: r }  -> bump sees 0,1,2 across the
//                                          three iterations (prints 3)
//
// Was RED: the hoist in ast_transform judged `bump` loop-invariant (it
// names no item) and emitted `const r = bump(g.n)` BEFORE the loop while
// `captured { n: r }` kept writing `g.n` inside — every iteration
// re-bumped the pre-loop 0 and printed 1. Silent wrong-answer, not a
// refusal — the dangerous kind. Surfaced by AoC day22's fight loop,
// which routes around it with value-recursion instead.
//
// Expected output: 3 (bump applied once per iteration, 0->1->2->3).
import std/io

pub tor bump { x: i64 } -> i64

bump = if(x >= 0)
| then -> x + 1
| else -> x

capture { n: 0[i64] }
! as g |> for(0..3)
    ! each _ |> bump(x: g.n): r
        |> captured { n: r }
| captured fin
    |> std/io:print.ln("{{ fin.n:d }}")
