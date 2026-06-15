// NESTING SWEEP — capture under POSITION 0: flow-head (BASELINE).
// The construct (capture fold incrementing a counter once) is the top-level
// flow head, no enclosing branch. This baseline MUST work.
import std/io

capture { n: 0[i64] }
! as acc |> captured { n: acc.n + 1 }
| captured r |> std/io:print.ln("n={{ r.n:d }}")
