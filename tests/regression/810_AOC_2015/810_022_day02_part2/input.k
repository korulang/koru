// AoC 2015 Day 2 Part 2 — ribbon (2x3x4 → 34, 1x1x10 → 14; 48).
// PURE .k since 2026-06-12: parse-dims retired by regex NAMED GROUPS — the
// pattern is the branch's payload schema, the destructure takes delivery,
// and the i64 types convert text→int at the splice. The ledger is empty.

import std/io
import std/fs
import std/regex

capture { ribbon: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_022_day02_part2/input.txt")
    ! line s |> std/regex:match(s)
        | `(?<l>[0-9]+)x(?<w>[0-9]+)x(?<h>[0-9]+)` { l: i64, w: i64, h: i64 } |> captured {
            ribbon: acc.ribbon + 2*@min(l+w, w+h, h+l)
                + l*w*h
        }
        | no-match |> std/io:print.ln("BAD LINE {{ s:s }}")
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.ribbon:d }}")
