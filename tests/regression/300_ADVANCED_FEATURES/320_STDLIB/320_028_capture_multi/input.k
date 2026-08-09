// Test: ~capture with multiple accumulated fields, as a SUBFLOW implementation.
// One pass through the data, multiple cells in one block, pure next-state
// semantics (compute the entire next state at once). Also exercises the
// multi-FIELD multi-LINE captured block.
// Values: 3, 1, 4, 1, 5 -> sum=14, max=5.

import std/io
import std/control

tor compute-stats {} -> { sum: i32, max: i32 }

compute-stats = capture { sum: 0[i32], max: 0[i32] }
! as c |> for(&[_]i32{ 3, 1, 4, 1, 5 })
    ! each val |> captured {
        sum: c.sum + val,
        max: if (val > c.max) val else c.max
    }
| captured final -> { final.sum, final.max }

compute-stats(): r |> std/io:print.ln("sum={{ r.sum:d }} max={{ r.max:d }}")
