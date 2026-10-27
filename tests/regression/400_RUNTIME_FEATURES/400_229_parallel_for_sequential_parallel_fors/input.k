// Pins: two SEQUENTIAL [parallel]fors are legal — the nesting wall covers
// only a [parallel] scope inside a [parallel]for's body, not sibling
// scopes in one chain.
import std/io

capture { acc: 0[i64] }
! as a |> [parallel]for(1..101)
    ! each i |> captured { acc: a.acc + @as(i64, @intCast(i)) }
| captured r |> [parallel]for(1..101)
    ! each i |> captured { acc: r.acc + 1 }
| captured s |> std/io:print.ln("{{ s.acc:d }}")
