// NESTING SWEEP — foreach under a SCALAR branch (position 1).
// The construct is nested under std/args:count()'s `| count _` scalar branch
// (no obligation). Grounded on 630_004 (read-lines under scalar anchor).
import std/io
import std/args

std/args:count(): _ |> for(0..3)
    ! each _ |> _
    | done |> std/io:print.ln("done")
