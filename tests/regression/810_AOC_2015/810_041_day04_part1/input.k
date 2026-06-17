// AoC 2015 Day 4 Part 1 — AdventCoin: lowest n where md5(key++n) starts
// with N hex zeros (abcdef → 609043, pqrstuv → 1048970; independently
// oracle-verified). NOW PURE .k: the unbounded SEARCH is a Koru label fold
// (#search/@search threads n through payloads, no mutation — 210_123); the
// per-candidate md5-check is the std/crypto leaf (hash key++decimal(n), test
// the hex-zero prefix). Koru owns the search; the leaf owns only the crypto.

import std/io
import std/fs
import std/crypto

pub event mine { key: []const u8, zeros: i64 }
| found i64

mine = #search std/crypto:md5-check(key, n: 1, zeros)
| miss v |> @search(key, n: v, zeros)
| found r => found r

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_041_day04_part1/input.txt")
! line k |> mine(key: k, zeros: 5)
    | found n |> std/io:print.ln("{{ n:d }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
