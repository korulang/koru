// AoC 2015 Day 13 Part 1 — optimal circular seating (statement example:
// 330). Koru: match dispatches the two sentence forms (gain vs lose) AND
// extracts names + amount (named groups, typed destructure). Table +
// permutation search are leaves (day-9 family).
// Ledger: happiness table ← collections; permutations ← host search.

import std/io
import std/fs
import std/regex

pub event pref { a: []const u8, b: []const u8, amt: i64, sign: i64 }

pub event best-seating {}
| happiness i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_131_day13_part1/input.txt")
! line l |> std/regex:match(l)
    | `(?<a>[A-Za-z]+) would gain (?<amt>[0-9]+) happiness units by sitting next to (?<b>[A-Za-z]+).` { a, amt: i64, b } |> pref(a, b, amt, sign: 1)
    | `(?<a>[A-Za-z]+) would lose (?<amt>[0-9]+) happiness units by sitting next to (?<b>[A-Za-z]+).` { a, amt: i64, b } |> pref(a, b, amt, sign: -1)
    | no-match |> std/io:print.ln("BAD: {{ l:s }}")
| done _ |> best-seating()
    | happiness h |> std/io:print.ln("{{ h:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
