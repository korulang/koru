// AoC 2015 Day 4 Part 1 — AdventCoin: lowest n where md5(key++n) starts
// with N hex zeros (abcdef → 609043, pqrstuv → 1048970; independently
// oracle-verified). The unbounded search is a LABEL LOOP — state threads
// through payloads, no mutation. Ledger: md5-check ← std/crypto leaf.

import std/io
import std/fs

pub event mine { key: []const u8, zeros: i64 }
| found i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_041_day04_part1/input.txt")
! line k |> mine(key: k, zeros: 5)
    | found n |> std/io:print.ln("{{ n:d }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
