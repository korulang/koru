// RED PIN — auto-discharge does NOT reach a <list!> binding dropped AFTER a
// for-loop. Simple-drop auto-discharge works (660_006), but here the list is
// live across the loop and gets no auto-inserted free → it leaks at runtime
// (GPA detector fails). A leak is always a bug; this stays RED until
// auto-discharge handles the post-loop drop. Same family as the existing
// 330_053_for_loop_obligation_escape pin.
//
// WORKAROUND (green today): put `| done |> std/list:free(xs)` on the for — see
// 660_012. This pin is the version WITHOUT the explicit free, to track the gap.
import std/io
import std/list

std/list:new(i64)
| list xs |> std/list:push(xs, v: 10) |> std/list:push(xs, v: 20) |> std/list:len(xs): n |> for(0..n)
        ! each i |> std/list:get(xs, i)
            | item v |> std/io:print.ln("{{ v:d }}")
            | out-of-bounds |> _
| err e |> std/io:print.ln("ERR {{ e:s }}")
