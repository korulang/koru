// NESTING SWEEP — strbranch nested UNDER a capture cell (position 5).
// Terminals write `captured {...}` to use the cell (mirrors 670_035).
import std/io
import std/string

capture { k: 0[i64] }
! as acc |> std/string:from-page("x")
    | ok s |> std/string:free(s) |> captured { k: acc.k + 1 }
    | err _ |> captured { k: acc.k + 1 }
| captured _ |> std/io:print.ln("ok")
