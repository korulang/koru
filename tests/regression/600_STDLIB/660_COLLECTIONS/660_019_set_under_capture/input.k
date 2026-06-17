// FIXED 2026-06-17 (was RED) — capture nested under a collection's <set!>
// obligation. The capture transform lowers the `! as` body and the `| captured`
// after-read into two SIBLING `branch=''` continuations; the auto-discharge
// inserter read each as an independent flow exit and discharged the outer <set!>
// at the end of BOTH — here the body's spurious free landed BEFORE `count`, so
// `count` read a freed set, GPA-aborted, and ALL output was DROPPED (expected 1,
// got nothing). Fix: auto_discharge_inserter now recognizes that multiple
// `branch=''` siblings are SEQUENTIAL steps (the emitter concatenates them), so
// an inherited obligation flows through and is discharged ONCE, at the final
// sibling (`in_sequential_prefix`). Loop variant (was a double-free) is 660_020.
// Sibling of the 2026-06-15 effect-under-obligation output-drop root.
import std/io
import std/set

std/set:new()
| set s |> capture { x: 0[i64] }
    ! as pos |> captured { x: pos.x + 1 } |> std/set:add(s, v: pos.x)
    | captured _ |> std/set:count(s)
        | count n |> std/io:print.ln("{{ n:d }}")
| err e |> std/io:print.ln("ERR {{ e:s }}")
