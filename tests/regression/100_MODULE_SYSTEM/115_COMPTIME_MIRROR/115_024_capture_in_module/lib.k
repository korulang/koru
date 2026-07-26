import std/io

pub tor run {}
run = capture { n: 0[i64] }
! as acc |> captured { n: acc.n + 1 }
| captured r |> std/io:print.ln("n={{ r.n:d }}")
