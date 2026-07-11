// NESTING SWEEP — strbranch at POSITION 3 (under an EFFECT branch).
// The strbranch construct is nested under the per-line effect branch of
// read-lines (! line _). It fires once per input line (5 lines), printing
// "ok" and freeing its own view each time.
import std/io
import std/fs
import std/string

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
! line _ |> std/string:from-page(text: "x")
    | ok s |> std/io:print.ln("ok") |> std/string:free(s)
    | err _ |> std/io:print.ln("err")
| done _ |> _
| failed _ |> _
