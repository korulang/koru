// RED PIN — streaming into a list via read-lines is blocked. A list created as a
// plain `| list xs` branch, with read-lines nested under it, produces NO output:
// the nested effect doesn't lower outside flow-top / effect-cell position.
//
// Grounded contrast:
//   - read-lines as the flow HEAD works (it prints "done").
//   - read-lines nested under `capture ! as acc` works (green AoC day1).
//   - read-lines nested under `new | list xs |>` (here) drops its output.
//
// This is the implementation diverging from the locked design: "a collection is
// a capture whose value is an indexable container." The list must be CAPTURE-
// SHAPED (an effect-cell, like `! as acc`) to compose with effect-streaming.
// Until then, the canonical AoC "stream input into a collection" pattern can't
// be expressed. Goes green when list creation is capture-shaped (or the effect
// lowers correctly under a runtime branch).
import std/io
import std/fs
import std/list

std/list:new-i64()
| list xs |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
    ! line _ |> _
    | done _ |> std/io:print.ln("done") |> std/list:free(xs)
    | failed _ |> std/io:print.ln("failed") |> std/list:free(xs)
| err _ |> std/io:print.ln("err")
