// AoC 2015 Day 2 Part 2 — ribbon: smallest face perimeter + cubic volume
// (2x3x4 → 34, 1x1x10 → 14; total = 48). PURE .k — see the .kz ledger.

import std/io

const { presents: &[_][]const u8{ "2x3x4", "1x1x10" } }

pub event parse-dims { line: []const u8 }
| dims { l: i64, w: i64, h: i64 }

capture { ribbon: 0[i64] }
! as acc |> for(presents)
    ! each line |> parse-dims(line)
        | dims { l, w, h } |> captured {
            ribbon: acc.ribbon + 2*@min(l+w, w+h, h+l)
                + l*w*h
        }
| captured total |> std/io:print.ln("{{ total.ribbon:d }}")
