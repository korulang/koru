// NESTING SWEEP — foreach under FLOW HEAD (position 0, BASELINE).
// The construct (a for(0..3) ! each loop printing "done" on | done) is the
// top-level flow head, no enclosing branch. This MUST work; it is the baseline
// every other position is measured against.
import std/io

for(0..3)
! each _ |> _
| done |> std/io:print.ln("done")
