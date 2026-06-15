// NESTING SWEEP — foreach under a CAPTURE cell (position 5).
// The construct is nested under `capture { k: 0[i64] } ! as acc`. The foreach
// runs the cell's body; on its terminal `| done` it emits `captured {...}` to
// resolve the fold, and the `| captured _` terminal prints "done" once.
// Grounded on 320_098 (capture under branch) + 810_012 (for nested under
// `! as acc`, captured emitted to drive the fold to `| captured`).
import std/io

capture { k: 0[i64] }
! as acc |> for(0..3)
    ! each _ |> _
    | done |> captured { k: acc.k + 1 }
| captured _ |> std/io:print.ln("done")
