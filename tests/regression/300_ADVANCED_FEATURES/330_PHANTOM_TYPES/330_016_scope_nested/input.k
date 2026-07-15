import std/control
import app/fs

for(0..2)
! each _ |> app/fs:open(path: "outer.txt"): of |> for(0..2)
    ! each _ |> app/fs:open(path: "inner.txt"): inf
    | done |> _
| done |> _
