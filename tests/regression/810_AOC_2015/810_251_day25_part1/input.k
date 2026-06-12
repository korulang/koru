// AoC 2015 Day 25 — the code at (row, col) of the diagonal table
// (statement table: row 6, col 6 → 27995004). The ITERATION is pure Koru:
// a for over the runtime-computed index drives multiply-mod folds in the
// cell. Ledger: two-int parse ← groups/typed destructure.

import std/io
import std/fs

pub event parse-pos { line: []const u8 }
| pos { r: i64, c: i64 }

capture { code: 20151125[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_251_day25_part1/input.txt")
    ! line l |> parse-pos(line: l)
        | pos { r, c } |> for(0..(@as(usize, @intCast(@divTrunc((r + c - 1) * (r + c - 2), 2) + c - 1))))
            ! each _ |> captured { code: @mod(acc.code * 252533, 33554393) }
            | done |> _
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.code:d }}")
