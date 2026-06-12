// AoC 2015 Day 12 Part 2 — sum numbers, but ignore any OBJECT (and its
// children) containing the value "red" (arrays with "red" still count).
// Statement examples: 6, 4, 0, 6. Ledger: structural JSON walk ← store +
// string-ops (part 1's flat char machine can't see object boundaries).

import std/io
import std/fs

pub event sum-no-red { s: []const u8 }
| total i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_122_day12_part2/input.txt")
! line l |> sum-no-red(s: l)
    | total t |> std/io:print.ln("{{ t:d }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
