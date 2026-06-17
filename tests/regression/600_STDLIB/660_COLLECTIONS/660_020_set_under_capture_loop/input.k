// PIN (sibling of 660_019) — capture nested under a collection's <set!>
// obligation, this time driving a LOOP in the `! as` body. The earlier bug:
// the capture lowering emits the `! as` body chain and the `| captured`
// after-read chain as two sibling `branch=''` continuations; auto-discharge
// read each as an independent flow exit and discharged the outer <set!> at the
// end of BOTH — here a DOUBLE-FREE (the body's free fires after the loop, then
// again after count), GPA-aborting. Adding 0,1,2 to the set => 3 distinct keys.
// The set obligation must be discharged exactly ONCE, after the after-read.
import std/io
import std/set

std/set:new()
| set s |> capture { x: 0[i64] }
    ! as pos |> for(0..3)
        ! each i |> std/set:add(s, v: @as(i64, @intCast(i)))
    | captured _ |> std/set:count(s)
        | count n |> std/io:print.ln("{{ n:d }}")
| err e |> std/io:print.ln("ERR {{ e:s }}")
