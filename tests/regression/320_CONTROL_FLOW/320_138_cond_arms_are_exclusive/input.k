// `cond` is multi-way DISPATCH (320_133), and dispatch is EXCLUSIVE: the arm
// whose guard matches runs, and no other one does.
//
// This program is the smallest shape that can tell the difference. Arm 1 sets
// v := 0; arm 2's guard is `v == 0`, so if arm 2 is reached at all it undoes
// arm 1 and prints v=1. Exclusive dispatch prints v=0. Only a lowering that
// cannot re-test a later guard against state an earlier arm just wrote passes
// — an `if / else if` cascade does, N sibling blocks do not.
//
// EFFECT-position arms (`|>`) are the ones that can tell: a value arm returns,
// so it stops the fall-through by accident whatever the lowering is. Every
// toggle written as a cond is this shape — koru-examples' gallery had a clock
// whose `space` arm set running := 0 and whose next arm set it back, so it
// never paused.
import std/io
import std/store

std/store:new(s) { v: 1[i64] }

tor toggle { ch: u8 }
toggle = cond(ch)
| c x when x == 't' and s.v == 1 |> std/store:stored { s.v: 0 }
| c x when x == 't' and s.v == 0 |> std/store:stored { s.v: 1 }
| c _ |> _

toggle(ch: 't')
std/io:print.ln("v={{ s.v:d }}")
