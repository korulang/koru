// NESTING SWEEP — foreach under a FOR-EACH branch (position 4).
// The construct is nested under an outer for(0..3)'s `! each _` handler. The
// outer loop fires three times; each iteration runs the inner foreach, which
// prints "done" on its `| done`. So "done" prints three times. The outer
// loop's own `| done` is a discard. Grounded on 640_002 (for ! each pure-k).
import std/io

for(0..3)
! each _ |> for(0..3)
    ! each _ |> _
    | done |> std/io:print.ln("done")
| done |> _
