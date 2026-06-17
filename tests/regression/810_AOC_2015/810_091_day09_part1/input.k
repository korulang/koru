// AoC 2015 Day 9 Part 1 — shortest route visiting every city once
// (statement example: London/Dublin/Belfast → 605). Koru: match extracts
// the edge (named groups, typed distance); the flow collects and queries.
// Ledger: distance table ← collections; permutation search ← host.

import std/io
import std/fs
import std/regex

pub event edge { a: []const u8, b: []const u8, d: i64 }

pub event best { longest: i64 }
| dist i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_091_day09_part1/input.txt")
! line l |> std/regex:match(l)
    | `(?<a>[A-Za-z]+) to (?<b>[A-Za-z]+) = (?<d>[0-9]+)` { a, b, d: i64 } |> edge(a, b, d)
    | no-match |> std/io:print.ln("BAD: {{ l:s }}")
| done _ |> best(longest: 0)
    | dist d |> std/io:print.ln("{{ d:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
