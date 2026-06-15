// NESTING SWEEP — ifcond under a for-each branch (for(0..3) `! each`).
// The nested construct fires once per iteration (0,1,2) → three "then" lines.
import std/io

for(0..3)
! each _ |> if(1 == 1)
    | then |> std/io:print.ln("then")
    | else |> std/io:print.ln("else")
| done |> _
