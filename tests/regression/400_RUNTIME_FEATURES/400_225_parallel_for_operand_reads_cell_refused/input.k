// Pins: a `captured` write under [parallel] whose fold operand reads the
// partitioned cell again is not a fold — `acc + i*acc` looks `+`-shaped at
// the top level, but the join's combine can only replay `cell op e_i` when
// `e_i` is cell-free. Serial answer is 9! = 362880; partitioned, the
// partials start at the identity and the join silently miscombines.
import std/io

capture { acc: 1[i64] }
! as a |> [parallel]for(1..9)
    ! each i |> captured { acc: a.acc + @as(i64, @intCast(i)) * a.acc }
| captured r |> std/io:print.ln("{{ r.acc:d }}")
