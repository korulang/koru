// AoC 2015 Day 18 Part 1 — Conway lights, 6x6 statement grid, 4 steps →
// 4 lights on. The STEP LOOP is Koru (for over 0..4); the grid and the
// neighbor rule are leaves. Ledger: grid ← collections.

import std/io
import std/fs

pub event grid-row { line: []const u8 }

pub event life-step { stuck: i64 }

pub event lit {}
| count i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_181_day18_part1/input.txt")
! line l |> grid-row(line: l)
| done _ |> for(0..4)
    ! each _ |> life-step(stuck: 0)
    | done |> lit()
        | count n |> std/io:print.ln("{{ n:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
