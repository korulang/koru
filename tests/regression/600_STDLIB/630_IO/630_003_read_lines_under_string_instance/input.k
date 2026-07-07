// Matrix: read-lines nested under a String<instance!> obligation (via take).
// Same class as 630_002 (view!), different obligation STATE — confirms the fix
// is about the obligation, not a specific phantom state.
import std/io
import std/fs
import std/string

std/string:from-page(text: "x")
| ok s |> std/string:take(s): o |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
        ! line _ |> _
        | done _ |> std/io:print.ln("done") |> std/string:free(s: o)
        | failed _ |> std/io:print.ln("failed") |> std/string:free(s: o)
| err _ |> std/io:print.ln("err")
