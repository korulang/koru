// Matrix POSITIVE ANCHOR: read-lines under a SCALAR branch (args:count, no
// obligation) must always work. If a future change to the effect/obligation
// scope logic breaks the no-obligation path, this catches it.
import std/io
import std/fs
import std/args

std/args:count()
| count _ |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
    ! line _ |> _
    | done _ |> std/io:print.ln("done")
    | failed _ |> std/io:print.ln("failed")
