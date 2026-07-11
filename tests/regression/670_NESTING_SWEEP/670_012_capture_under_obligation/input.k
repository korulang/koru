// NESTING SWEEP — capture under POSITION 2: obligation branch.
// capture fold (increments a counter once) nested under `| ok s` from
// from-page, which carries a String<view!> cleanup obligation. The view `s`
// must be freed on EVERY terminal of the nested construct (here the single
// `| captured r` terminal) or KORU030 fires.
import std/io
import std/string

std/string:from-page(text: "x")
| ok s |> capture { n: 0[i64] }
    ! as acc |> captured { n: acc.n + 1 }
    | captured r |> std/io:print.ln("n={{ r.n:d }}") |> std/string:free(s)
| err _ |> std/io:print.ln("err")
