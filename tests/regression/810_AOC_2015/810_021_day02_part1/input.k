// AoC 2015 Day 2 Part 1 — "I Was Told There Would Be No Math"
// (statement examples: 2x3x4 → 58, 1x1x10 → 43; total = 101).
// PURE .k STRUCTURE — the .kz facet beside this file is the day's open
// FRONTIER LEDGER: every proc in it is a gap the climb still owes
// (here: parse-dims, which regex GROUPS will retire).

import std/io
import std/control

const { presents: &[_][]const u8{ "2x3x4", "1x1x10" } }

pub event parse-dims { line: []const u8 }
| dims { l: i64, w: i64, h: i64 }

capture { paper: 0[i64] }
! as acc |> for(presents)
    ! each line |> parse-dims(line)
        | dims d |> captured {
            paper: acc.paper + 2*d.l*d.w + 2*d.w*d.h + 2*d.h*d.l
                + @min(d.l*d.w, d.w*d.h, d.h*d.l)
        }
| captured total |> std/io:print.ln("{{ total.paper:d }}")
