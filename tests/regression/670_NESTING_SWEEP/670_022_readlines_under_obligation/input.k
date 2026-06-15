// NESTING SWEEP — readlines nested UNDER an obligation branch (position 2).
// The obligation binding `s` (String<view!>) must be discharged with
// std/string:free(s) on EVERY terminal of the nested construct (| done, | failed)
// or KORU030 fires.
import std/io
import std/fs
import std/string

std/string:from-page(text: "x")
| ok s |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
    ! line _ |> _
    | done _ |> std/io:print.ln("done") |> std/string:free(s)
    | failed _ |> std/io:print.ln("failed") |> std/string:free(s)
| err _ |> _
