// AoC 2015 Day 25 — the code at (row, col) of the diagonal table
// (statement table: row 6, col 6 → 27995004). PURE .k since 2026-06-12:
// parse-pos retired by regex NAMED GROUPS with typed destructure. The
// ITERATION was always pure Koru: a for over the runtime-computed index
// drives multiply-mod folds in the cell. Ledger is empty.

import std/io
import std/fs
import std/regex

capture { code: 20151125[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_251_day25_part1/input.txt")
    ! line l |> std/regex:match(l)
        | `(?<r>[0-9]+) (?<c>[0-9]+)` { r: i64, c: i64 } |> for(0..(@as(usize, @intCast(@divTrunc((r + c - 1) * (r + c - 2), 2) + c - 1))))
            ! each _ |> captured { code: @mod(acc.code * 252533, 33554393) }
            | done |> _
        | no-match |> std/io:print.ln("BAD LINE {{ l:s }}")
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.code:d }}")
