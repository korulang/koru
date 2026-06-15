// NESTING SWEEP — readlines nested UNDER a capture cell (position 5).
// The construct's terminals write `captured {...}` to use the cell (mirrors the
// passing 670_035 foreach_under_capture pattern); | captured prints once.
import std/io
import std/fs

capture { k: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
    ! line _ |> _
    | done _ |> captured { k: acc.k + 1 }
    | failed _ |> captured { k: acc.k + 1 }
| captured _ |> std/io:print.ln("done")
