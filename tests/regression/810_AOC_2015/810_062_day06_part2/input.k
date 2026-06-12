// AoC 2015 Day 6 Part 2 — brightness. Statement examples sequenced:
// BRIGHTNESS: on 0,0 (+1) then toggle-all (+2 each) → 2000001.
// Koru does the DISPATCH: three full-match patterns classify the
// instruction; the grid and coordinate extraction are leaves.
// Ledger: grid ← store (gap 2); coords ← regex groups/TDFA (gap 1) —
// `(?<x1>\d+),(?<y1>\d+)` destructure retires apply's re-parse.

import std/io
import std/fs
import std/regex

pub event apply { op: i64, line: []const u8 }

pub event lit-count {}
| count i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_062_day06_part2/input.txt")
! line l |> std/regex:match(l)
    | `turn on [0-9]+,[0-9]+ through [0-9]+,[0-9]+` _ |> apply(op: 1, line: l)
    | `turn off [0-9]+,[0-9]+ through [0-9]+,[0-9]+` _ |> apply(op: 2, line: l)
    | `toggle [0-9]+,[0-9]+ through [0-9]+,[0-9]+` _ |> apply(op: 3, line: l)
    | no-match |> std/io:print.ln("BAD: {{ l:s }}")
| done _ |> lit-count()
    | count n |> std/io:print.ln("{{ n:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
