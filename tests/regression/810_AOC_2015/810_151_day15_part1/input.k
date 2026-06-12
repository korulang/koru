// AoC 2015 Day 15 Part 1 — best cookie from 100 teaspoons of two
// ingredients (statement example: 62842880). The AMOUNT LOOP is Koru
// (for over 0..101); scoring over the stored ingredient table is the
// leaf. Ledger: ingredient table ← store; property parse ← groups.

import std/io
import std/fs

pub event add-ingredient { line: []const u8 }

pub event score { a: i64, calorie-target: i64 }
| points i64

capture { best: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_151_day15_part1/input.txt")
    ! line l |> add-ingredient(line: l)
    | done _ |> for(0..101)
        ! each a |> score(a: @intCast(a), calorie-target: 0)
            | points p |> captured { best: @max(acc.best, p) }
        | done |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.best:d }}")
