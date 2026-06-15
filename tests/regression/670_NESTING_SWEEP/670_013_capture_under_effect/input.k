// NESTING SWEEP — capture under POSITION 3: effect branch.
// capture fold (increments a counter once) nested under the `! line _` effect
// body of read-lines. The input.txt has 5 lines, so the fresh-per-fire fold
// fires 5 times, each producing `n=1` — deterministic output (5 identical
// lines). `| done`/`| failed` are required effect terminals.
import std/io
import std/fs

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
! line _ |> capture { n: 0[i64] }
    ! as acc |> captured { n: acc.n + 1 }
    | captured r |> std/io:print.ln("n={{ r.n:d }}")
| done _ |> _
| failed _ |> _
