// AoC 2015 Day 6 Part 2 — brightness. Statement examples sequenced:
// BRIGHTNESS: on 0,0 (+1) then toggle-all (+2 each) → 2000001.
// Koru does the DISPATCH and the COORDINATES: three full-match patterns
// classify the instruction, named groups deliver the rectangle typed.
// Ledger: brightness grid ← store (gap 2).

import std/io
import std/fs
import std/regex

pub event apply { op: i64, x1: i64, y1: i64, x2: i64, y2: i64 }

pub event lit-count {}
| count i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_062_day06_part2/input.txt")
! line l |> std/regex:match(l)
    | `turn on (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: i64, y1: i64, x2: i64, y2: i64 } |> apply(op: 1, x1, y1, x2, y2)
    | `turn off (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: i64, y1: i64, x2: i64, y2: i64 } |> apply(op: 2, x1, y1, x2, y2)
    | `toggle (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: i64, y1: i64, x2: i64, y2: i64 } |> apply(op: 3, x1, y1, x2, y2)
    | no-match |> std/io:print.ln("BAD: {{ l:s }}")
| done _ |> lit-count()
    | count n |> std/io:print.ln("{{ n:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
