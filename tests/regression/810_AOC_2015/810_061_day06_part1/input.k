// AoC 2015 Day 6 Part 1 — a million lights. Statement examples sequenced:
// on-all (1000000) → toggle row 0 (999000) → off 2x2 (998996).
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

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_061_day06_part1/input.txt")
! line l |> std/regex:match(l)
    | `turn on [0-9]+,[0-9]+ through [0-9]+,[0-9]+` _ |> apply(op: 1, line: l)
    | `turn off [0-9]+,[0-9]+ through [0-9]+,[0-9]+` _ |> apply(op: 2, line: l)
    | `toggle [0-9]+,[0-9]+ through [0-9]+,[0-9]+` _ |> apply(op: 3, line: l)
    | no-match |> std/io:print.ln("BAD: {{ l:s }}")
| done _ |> lit-count()
    | count n |> std/io:print.ln("{{ n:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
