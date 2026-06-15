// NESTING SWEEP — foreach under an EFFECT branch (position 3).
// The construct is nested under read-lines' `! line _` effect handler. The
// foreach runs once per line; "done" prints per line. The enclosing flow's
// terminals (| done / | failed) are discards. Grounded on 630_004 (read-lines
// shape) + 640_002 (for ! each pure-k form).
import std/io
import std/fs

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
! line _ |> for(0..3)
    ! each _ |> _
    | done |> std/io:print.ln("done")
| done _ |> _
| failed _ |> _
