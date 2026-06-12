// AoC 2015 Day 21 Part 1 — cheapest shop loadout that beats the boss.
// Boss stats are personal-only; this boss (104hp/8dmg/1armor) is
// CONSTRUCTED and python-oracled (cheapest win 78; the statement's demo
// boss 12/7/2 is degenerate — a bare dagger wins). Fight math is the
// statement's (ceil-turns comparison). Ledger: shop search ← host.

import std/io
import std/fs

pub event shop { line: []const u8, want-loss: i64 }
| gold i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_211_day21_part1/input.txt")
! line l |> shop(line: l, want-loss: 0)
    | gold g |> std/io:print.ln("{{ g:d }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
