// AoC 2015 Day 19 Part 1 — distinct molecules after ONE replacement
// (statement: HOH with 3 rules → 4). Koru: match splits rule lines from
// the molecule line; set-of-results and replacement scan are leaves.
// Ledger: result set ← store; rule split ← groups.

import std/io
import std/fs
import std/regex

pub event add-rule { line: []const u8 }

pub event count-molecules { molecule: []const u8 }
| distinct i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_191_day19_part1/input.txt")
! line l |> std/regex:match(l)
    | `[A-Za-z]+ => [A-Za-z]+` _ |> add-rule(line: l)
    | `[A-Za-z]+` _ |> count-molecules(molecule: l)
        | distinct n |> std/io:print.ln("{{ n:d }}")
    | no-match |> _
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
