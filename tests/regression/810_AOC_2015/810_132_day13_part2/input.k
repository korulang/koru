// AoC 2015 Day 13 Part 1 — optimal circular seating (statement example:
// p2: add yourself at 0 (python-oracled: 286). Koru: match validates/dispatches the two sentence forms (gain vs
// lose); table + permutation search are leaves (day-9 family).
// Ledger: happiness table ← store; permutations ← host; names/amounts ←
// groups.

import std/io
import std/fs
import std/regex

pub event pref { line: []const u8, sign: i64 }

pub event add-self {}

pub event best-seating {}
| happiness i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_132_day13_part2/input.txt")
! line l |> std/regex:match(l)
    | `[A-Za-z]+ would gain [0-9]+ happiness units by sitting next to [A-Za-z]+.` _ |> pref(line: l, sign: 1)
    | `[A-Za-z]+ would lose [0-9]+ happiness units by sitting next to [A-Za-z]+.` _ |> pref(line: l, sign: -1)
    | no-match |> std/io:print.ln("BAD: {{ l:s }}")
| done _ |> add-self() |> best-seating()
    | happiness h |> std/io:print.ln("{{ h:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
