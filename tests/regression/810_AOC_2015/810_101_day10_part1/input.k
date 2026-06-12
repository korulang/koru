// AoC 2015 Day 10 Part 1 — look-and-say. Statement example: "1" after 5
// rounds → 312211 (the real puzzle runs 40 rounds on a personal input —
// same machinery, bigger n). The ROUND LOOP is Koru (for over 0..5, state
// held by the leaf between rounds); the string-building step is the leaf.
// Ledger: growing-string round ← store/string-ops (gaps 2+4).

import std/io
import std/fs

pub event ls-init { seed: []const u8 }

pub event ls-step {}

pub event ls-result {}
| said { s: []const u8, len: i64 }

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_101_day10_part1/input.txt")
! line seed |> ls-init(seed)
| done _ |> for(0..5)
    ! each _ |> ls-step()
    | done |> ls-result()
        | said { s, len } |> std/io:print.ln("{{ s:s }}") |> std/io:print.ln("{{ len:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
