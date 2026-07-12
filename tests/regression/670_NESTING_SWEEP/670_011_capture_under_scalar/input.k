// NESTING SWEEP — capture under POSITION 1: scalar branch.
// capture fold (increments a counter once) nested under `| count _`.
import std/io
import std/args

std/args:count(): _ |> capture { n: 0[i64] }
    ! as acc |> captured { n: acc.n + 1 }
    | captured r |> std/io:print.ln("n={{ r.n:d }}")
