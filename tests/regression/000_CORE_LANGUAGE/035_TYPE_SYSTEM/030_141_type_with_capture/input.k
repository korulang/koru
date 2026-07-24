// Pins a DECLARED nominal type as the accumulator of an effect cell
// (seed block + `! as`, 320_042). The accumulator is a DECLARED nominal type — the capture cell holds a
// value of a Koru-minted type, so the cell must resolve the declared
// type's identity, not a pasted Zig string. (The stamped-name variant
// of this pin is 030_121.)

import std/types
import std/io
import std/control

std/types:struct(Acc) {
    total: i64,
    count: i64,
}

capture { a: Acc{ .total = 0, .count = 0 } }
! as state |> for(&[_]i64{ 10, 20, 30, 40 })
    ! each n |> captured { a: Acc{ .total = state.a.total + n, .count = state.a.count + 1 } }
| captured final |> std/io:print.ln("Total: {{ final.a.total:d }}, Count: {{ final.a.count:d }}")
