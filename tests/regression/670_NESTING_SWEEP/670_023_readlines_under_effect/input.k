// NESTING SWEEP — readlines nested UNDER an effect branch (position 3).
// The enclosing read-lines fires `! line` per line; under that effect branch
// we nest a second readlines construct.
import std/io
import std/fs

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
  ! line _ |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
      ! line _ |> _
      | done _ |> std/io:print.ln("done")
      | failed _ |> std/io:print.ln("failed")
  | done _ |> _
  | failed _ |> _
