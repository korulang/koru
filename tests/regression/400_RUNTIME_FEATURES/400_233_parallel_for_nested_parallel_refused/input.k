// Pins: a [parallel]for inside a [parallel]for's each body refuses — the
// lowering emits one worker fn per for, and a second fork inside it used
// to reach Zig as shadow errors on `__koru_par_*` names the author never
// wrote.
import std/io

capture { acc: 0[i64] }
! as a |> [parallel]for(1..5)
    ! each i |> [parallel]for(1..5)
        ! each j |> captured { acc: a.acc + @as(i64, @intCast(i * j)) }
| captured r |> std/io:print.ln("{{ r.acc:d }}")
