// AoC 2015 Day 11 Part 1 — next valid password (abcdefgh → abcdffaa,
// ghijklmn → ghjaabcc). One next-password per input line.
// Ledger (FAT): the increment-until-valid loop lives in the leaf — the
// Koru spelling (label loop in a subflow) panics the compiler (210_123);
// string mutation also wants string-ops (gap 4). Per-line dispatch is Koru.

import std/io
import std/fs

pub event next-password { s: []const u8 }
| pw []const u8

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_111_day11_part1/input.txt")
! line l |> next-password(s: l)
    | pw p |> std/io:print.ln("{{ p:s }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
