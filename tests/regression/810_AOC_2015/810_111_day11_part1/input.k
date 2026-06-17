// AoC 2015 Day 11 Part 1 — next valid password (abcdefgh → abcdffaa,
// ghijklmn → ghjaabcc). One next-password per input line.
// The increment-until-valid SEARCH IS KORU — a label fold on the subflow
// RHS re-invokes one increment+validate step per iteration (210_123
// greened; the loop came home). Ledger: buffer copy (prep) ← collections;
// increment + validate themselves ← string-ops (gap 4).

import std/io
import std/fs

pub event prep { s: []const u8 }
| ready []u8

pub event step { p: []u8 }
| pw []const u8
| again []u8

pub event next-password { p: []u8 }
| pw []const u8

next-password = #seek step(p)
| again t |> @seek(p: t)
| pw r => pw r

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_111_day11_part1/input.txt")
! line l |> prep(s: l)
    | ready b |> next-password(p: b)
        | pw p |> std/io:print.ln("{{ p:s }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
