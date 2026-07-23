// NESTING SWEEP — ifcond under a capture cell (`! as acc` fold body).
// The nested construct runs inside the fold body; each terminal folds the
// accumulator with a `captured {...}` event. The success path prints "then".
import std/io

capture { k: 0[i64] }
! as acc |> if(1 == 1)
    | then |> std/io:print.ln("then") |> captured { k: acc.k + 1 }
    | else |> captured { acc.k }
| captured _ |> _
