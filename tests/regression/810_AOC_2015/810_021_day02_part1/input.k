// AoC 2015 Day 2 Part 1 — wrapping paper (2x3x4 → 58, 1x1x10 → 43; 101).
// CANONICAL SHAPE: lines off disk. Ledger: parse-dims ← regex groups.

import std/io
import std/fs

pub event parse-dims { line: []const u8 }
| dims { l: i64, w: i64, h: i64 }

capture { paper: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_021_day02_part1/input.txt")
    ! line s |> parse-dims(line: s)
        | dims { l, w, h } |> captured {
            paper: acc.paper + 2*l*w + 2*w*h + 2*h*l
                + @min(l*w, w*h, h*l)
        }
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.paper:d }}")
