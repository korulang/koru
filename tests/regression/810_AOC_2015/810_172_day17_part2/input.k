// AoC 2015 Day 17 Part 1 — ways to fit exactly 25 liters (statement
// example: containers 20,15,10,5,5 p2: ways using the MINIMUM container count → 3). Ledger: subset
// search ← host recursion; sizes ← store. Line intake is Koru.

import std/io
import std/fs

pub event add-container { line: []const u8 }

pub event combos { target: i64, min-only: i64 }
| ways i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_172_day17_part2/input.txt")
! line l |> add-container(line: l)
| done _ |> combos(target: 25, min-only: 1)
    | ways w |> std/io:print.ln("{{ w:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
