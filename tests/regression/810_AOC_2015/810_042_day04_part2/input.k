// AoC 2015 Day 4 Part 2 — AdventCoin with SIX leading hex zeros
// (abcdef → 6742839; oracle-verified). NOW PURE .k: same Koru label-fold
// search as part 1, six zeros instead of five; the per-candidate md5-check is
// the std/crypto leaf. Koru owns the search; the leaf owns only the crypto.

import std/io
import std/fs
import std/crypto

pub tor mine { key: string, zeros: i64 } -> i64

mine = #search std/crypto:md5-check(key, n: 1, zeros)
| miss v |> @search(key, n: v, zeros)
| found r -> r

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_042_day04_part2/input.txt")
! line k |> mine(key: k, zeros: 6)
    | found n |> std/io:print.ln("{{ n:d }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
