// Pins: a second `captured` write to a field already folded under
// [parallel] escapes the combine-law check — the partition replays ONE
// combine per field, so `acc + i` then `acc * 2` composes to something no
// single fold proves. Serial answer 1004; partitioned, the second write
// silently wins inside each worker and the join miscombines.
import std/io

capture { acc: 0[i64] }
! as a |> [parallel]for(1..9)
    ! each i |> captured { acc: a.acc + @as(i64, @intCast(i)) } |> captured { acc: a.acc * 2 }
| captured r |> std/io:print.ln("{{ r.acc:d }}")
