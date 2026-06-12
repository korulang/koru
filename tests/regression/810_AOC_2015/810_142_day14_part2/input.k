// AoC 2015 Day 14 Part 2 — points: each second the leading reindeer gets
// a point; max points at t=1000 (statement: Dancer 689). The per-second
// race over N reindeer needs a TABLE of specs — ledgered to the store.

import std/io
import std/fs

pub event add-reindeer { line: []const u8 }

pub event race { seconds: i64 }
| points i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_142_day14_part2/input.txt")
! line l |> add-reindeer(line: l)
| done _ |> race(seconds: 1000)
    | points p |> std/io:print.ln("{{ p:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
