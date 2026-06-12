// AoC 2015 Day 2 Part 2 — ribbon (2x3x4 → 34, 1x1x10 → 14; 48).
// CANONICAL SHAPE: lines off disk. Ledger: parse-dims ← regex groups.

import std/io
import std/fs

pub event parse-dims { line: []const u8 }
| dims { l: i64, w: i64, h: i64 }

capture { ribbon: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_022_day02_part2/input.txt")
    ! line s |> parse-dims(line: s)
        | dims { l, w, h } |> captured {
            ribbon: acc.ribbon + 2*@min(l+w, w+h, h+l)
                + l*w*h
        }
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.ribbon:d }}")
