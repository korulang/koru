// NESTING SWEEP — ifcond under an effect branch (std/fs:read-lines `! line`).
// input.txt holds a single line, so the nested construct fires exactly once →
// one deterministic "then".
import std/io
import std/fs

std/fs:read-lines(path: "tests/regression/670_NESTING_SWEEP/670_043_ifcond_under_effect/input.txt")
! line _ |> if(1 == 1)
    | then |> std/io:print.ln("then")
    | else |> std/io:print.ln("else")
| done _ |> _
| failed _ |> _
