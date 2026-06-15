// Matrix: list ACTIVELY USED (push) inside the read-lines effect loop, then
// len + free after. The canonical AoC "stream input into a collection" pattern.
// Exercises both symptoms at once: the loop output must run (push each line) AND
// the <list!> obligation must discharge exactly once (free in done/failed) — no
// spurious in-loop free, no leak.
import std/io
import std/fs
import std/list

std/list:new(i64)
| list xs |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
    ! line _ |> std/list:push(xs, 1)
    | done _ |> std/list:len(xs)
        | len m |> std/io:print.ln("count={{ m:d }}") |> std/list:free(xs)
    | failed _ |> std/io:print.ln("failed") |> std/list:free(xs)
| err _ |> std/io:print.ln("err")
