// NESTING SWEEP — capture under POSITION 5: capture cell.
// The construct (an inner capture fold that increments a counter once) is
// nested under the `! as acc` body of an OUTER capture cell. The inner fold
// prints `n=1`; the outer cell's `| captured _` terminal is a no-op.
import std/io

capture { k: 0[i64] }
! as acc |> capture { n: 0[i64] }
    ! as inner |> captured { n: inner.n + 1 }
    | captured r |> std/io:print.ln("n={{ r.n:d }}")
| captured _ |> _
