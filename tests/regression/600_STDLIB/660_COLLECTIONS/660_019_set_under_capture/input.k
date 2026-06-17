// PIN (currently RED) — capture nested under a collection's <set!> obligation
// branch mis-composes with the obligation/auto-discharge machinery. Here the
// capture's `| captured` terminal output is DROPPED (prints nothing; expected
// 1). Under a read-lines loop the SAME shape instead double-frees the <set!>
// (counts are correct, then GPA "double free detected"). day03 is blocked on
// this: its walk logic is correct (verified 2,4,2 in a scratch run) but the
// set obligation discharge is buggy in this nesting. Sibling of the 2026-06-15
// effect-under-obligation output-drop root; this is its collection+capture
// manifestation. Belongs to the obligation work.
import std/io
import std/set

std/set:new()
| set s |> capture { x: 0[i64] }
    ! as pos |> captured { x: pos.x + 1 } |> std/set:add(s, v: pos.x)
    | captured _ |> std/set:count(s)
        | count n |> std/io:print.ln("{{ n:d }}")
| err e |> std/io:print.ln("ERR {{ e:s }}")
