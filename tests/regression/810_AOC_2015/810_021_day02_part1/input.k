// AoC 2015 Day 2 Part 1 — "I Was Told There Would Be No Math"
// (statement examples: 2x3x4 → 58, 1x1x10 → 43; total = 101).
// PURE .k STRUCTURE — the .kz facet beside this file is the day's open
// FRONTIER LEDGER: every proc in it is a gap the climb still owes
// (here: parse-dims, which regex GROUPS will retire).

import std/io

const { presents: &[_][]const u8{ "2x3x4", "1x1x10" } }

pub event parse-dims { line: []const u8 }
| dims { l: i64, w: i64, h: i64 }

capture { paper: 0[i64] }
! as acc |> for(presents)
    ! each line |> parse-dims(line)
        | dims { l, w, h } |> captured {
            paper: acc.paper + 2*l*w + 2*w*h + 2*h*l
                + @min(l*w, w*h, h*l)
        }
| captured total |> std/io:print.ln("{{ total.paper:d }}")
