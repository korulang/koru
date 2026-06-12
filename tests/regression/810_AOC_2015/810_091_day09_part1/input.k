// AoC 2015 Day 9 Part 1 — shortest route visiting every city once
// (statement example: London/Dublin/Belfast → 605). Koru: match validates
// and dispatches the edge form, the flow stores and queries. Ledger:
// distance table ← store; permutation search ← host; endpoints ← groups.

import std/io
import std/fs
import std/regex

pub event edge { line: []const u8 }

pub event best { longest: i64 }
| dist i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_091_day09_part1/input.txt")
! line l |> std/regex:match(l)
    | `[A-Za-z]+ to [A-Za-z]+ = [0-9]+` _ |> edge(line: l)
    | no-match |> std/io:print.ln("BAD: {{ l:s }}")
| done _ |> best(longest: 0)
    | dist d |> std/io:print.ln("{{ d:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
