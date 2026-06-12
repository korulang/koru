// AoC 2015 Day 18 Part 1 — Conway lights, 6x6 statement grid, p2: corners STUCK on, 5 steps → 17. The STEP LOOP is Koru (for over 0..4); the grid and the
// neighbor rule are leaves. Ledger: grid ← store.

import std/io
import std/fs

pub event grid-row { line: []const u8 }

pub event life-step { stuck: i64 }

pub event lit {}
| count i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_182_day18_part2/input.txt")
! line l |> grid-row(line: l)
| done _ |> for(0..5)
    ! each _ |> life-step(stuck: 1)
    | done |> lit()
        | count n |> std/io:print.ln("{{ n:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
