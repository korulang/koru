// NESTING SWEEP — readlines nested UNDER a scalar branch (position 1).
import std/io
import std/fs
import std/args

std/args:count(): _ |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
    ! line _ |> _
    | done _ |> std/io:print.ln("done")
    | failed _ |> std/io:print.ln("failed")
