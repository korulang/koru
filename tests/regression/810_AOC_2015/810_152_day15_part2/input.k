// AoC 2015 Day 15 Part 2 — best 500-calorie cookie (statement example:
// 57600000). The AMOUNT LOOP is Koru (for over 0..101) and the
// signed-property parse is Koru's now (named groups; `-?` inside a group
// is fine — the ban is groups UNDER quantifiers). Only the stored
// ingredient table is a leaf ← store.

import std/io
import std/fs
import std/regex

pub event add-props { cap: i64, dur: i64, fla: i64, tex: i64, cal: i64 }

pub event score { a: i64, calorie-target: i64 }
| points i64

capture { best: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_152_day15_part2/input.txt")
    ! line l |> std/regex:match(l)
        | `[A-Za-z]+: capacity (?<cap>-?[0-9]+), durability (?<dur>-?[0-9]+), flavor (?<fla>-?[0-9]+), texture (?<tex>-?[0-9]+), calories (?<cal>-?[0-9]+)` { cap: i64, dur: i64, fla: i64, tex: i64, cal: i64 } |> add-props(cap, dur, fla, tex, cal)
        | no-match |> std/io:print.ln("BAD LINE {{ l:s }}")
    | done _ |> for(0..101)
        ! each a |> score(a: @intCast(a), calorie-target: 500)
            | points p |> captured { best: @max(acc.best, p) }
        | done |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.best:d }}")
