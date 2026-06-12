// AoC 2015 Day 9 Part 2 — LONGEST route visiting every city once
// (statement example: London/Dublin/Belfast → 982). Koru: match extracts
// the edge (named groups, typed distance); the flow stores and queries.
// Ledger: distance table ← store; permutation search ← host.

import std/io
import std/fs
import std/regex

pub event edge { a: []const u8, b: []const u8, d: i64 }

pub event best { longest: i64 }
| dist i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_092_day09_part2/input.txt")
! line l |> std/regex:match(l)
    | `(?<a>[A-Za-z]+) to (?<b>[A-Za-z]+) = (?<d>[0-9]+)` { a, b, d: i64 } |> edge(a, b, d)
    | no-match |> std/io:print.ln("BAD: {{ l:s }}")
| done _ |> best(longest: 1)
    | dist d |> std/io:print.ln("{{ d:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
