// Pins: a `captured` write under [parallel] whose non-cell operand reads
// ONLY the item is still a provable fold — `acc + i*2` combines as `+=`,
// and a second field folding on its own (`cnt + 1`) partitions beside it.
import std/io

capture { acc: 0[i64], cnt: 0[i64] }
! as a |> [parallel]for(1..101)
    ! each i |> captured { acc: a.acc + @as(i64, @intCast(i)) * 2, cnt: a.cnt + 1 }
| captured r |> std/io:print.ln("{{ r.acc:d }} {{ r.cnt:d }}")
