// AoC 2015 Day 24 Part 1 — balance packages into 4 equal groups (with the trunk); quantum
// entanglement of the smallest front group (statement example → 44).
// Ledger: subset search ← host; weights ← store. Intake is Koru.

import std/io
import std/fs

pub event add-weight { line: []const u8 }

pub event balance { groups: i64 }
| qe i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_242_day24_part2/input.txt")
! line l |> add-weight(line: l)
| done _ |> balance(groups: 4)
    | qe q |> std/io:print.ln("{{ q:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
