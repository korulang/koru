// AoC 2015 Day 17 Part 1 — count container subsets summing to 25 (20,15,10,5,5 → 4).
//
// STATUS: intake works (read-lines → regex-typed → list:push; the effect/obligation
// fix unblocked it). The subset-count step needs a SECOND accumulator (capture) to
// fold over the list, nested under read-lines' `| done` — currently BLOCKED on the
// capture-at-nested-site transform gap (pinned minimally as 320_098). Goes green
// once 320_098 is fixed and the bitmask subset search is added. Shown: the intake,
// reporting len so the test is honest-red (len=5 ≠ 4) rather than crashing.
import std/io
import std/fs
import std/list
import std/regex

std/list:new(i64)
| list xs |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
    ! line l |> std/regex:match(l)
        | `(?<n>[0-9]+)` { n: i64 } |> std/list:push(xs, n)
        | no-match |> _
    | done _ |> std/list:len(xs)
        | len m |> std/io:print.ln("{{ m:d }}") |> std/list:free(xs)
    | failed e |> std/io:print.ln("FAILED {{ e:s }}") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
