// AoC 2015 Day 4 Part 2 — AdventCoin with SIX leading hex zeros
// (abcdef → 6742839; oracle-verified).
// The unbounded SEARCH IS KORU — a label fold on the subflow RHS threads
// n through payloads, no mutation (210_123 greened; the loop came home).
// Ledger: single md5-check ← std/crypto leaf.

import std/io
import std/fs

pub event check { key: []const u8, zeros: i64, n: i64 }
| found i64
| miss i64

pub event mine { key: []const u8, zeros: i64 }
| found i64

mine = #search check(key, zeros, n: 1)
| miss v |> @search(key, zeros, n: v)
| found r => found r

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_042_day04_part2/input.txt")
! line k |> mine(key: k, zeros: 6)
    | found n |> std/io:print.ln("{{ n:d }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
