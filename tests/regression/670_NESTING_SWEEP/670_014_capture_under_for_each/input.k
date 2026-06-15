// NESTING SWEEP — capture under POSITION 4: for-each branch.
// capture fold (increments a counter once) nested under the `! each _` body of
// a for-loop over 0..3. The fresh-per-fire fold fires 3 times, each producing
// `n=1` — deterministic output (3 identical lines). `| done` is the terminal.
import std/io

for(0..3)
! each _ |> capture { n: 0[i64] }
    ! as acc |> captured { n: acc.n + 1 }
    | captured r |> std/io:print.ln("n={{ r.n:d }}")
| done |> _
