// AoC 2015 Day 15 Part 2 — best cookie that totals exactly 500 calories
// (statement example: 57600000). Pure Koru: same flat-capture store and
// amount loop as part 1, plus calorie slots (e0, e1). A split scores normally
// only when cal0*a + cal1*(100-a) == 500; otherwise the score is gated to 0 by
// a branchless @intFromBool so it can never beat the running best.

import std/io
import std/fs
import std/regex

capture { c0: 0[i64], d0: 0[i64], f0: 0[i64], t0: 0[i64], e0: 0[i64], c1: 0[i64], d1: 0[i64], f1: 0[i64], t1: 0[i64], e1: 0[i64], idx: 0[i64], best: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_152_day15_part2/input.txt")
    ! line l |> std/regex:match(l)
        | `[A-Za-z]+: capacity (?<cap>-?[0-9]+), durability (?<dur>-?[0-9]+), flavor (?<fla>-?[0-9]+), texture (?<tex>-?[0-9]+), calories (?<cal>-?[0-9]+)` { cap: i64, dur: i64, fla: i64, tex: i64, cal: i64 } |> captured { c0: acc.c0 + cap * @as(i64, @intFromBool(acc.idx == 0)), d0: acc.d0 + dur * @as(i64, @intFromBool(acc.idx == 0)), f0: acc.f0 + fla * @as(i64, @intFromBool(acc.idx == 0)), t0: acc.t0 + tex * @as(i64, @intFromBool(acc.idx == 0)), e0: acc.e0 + cal * @as(i64, @intFromBool(acc.idx == 0)), c1: acc.c1 + cap * @as(i64, @intFromBool(acc.idx == 1)), d1: acc.d1 + dur * @as(i64, @intFromBool(acc.idx == 1)), f1: acc.f1 + fla * @as(i64, @intFromBool(acc.idx == 1)), t1: acc.t1 + tex * @as(i64, @intFromBool(acc.idx == 1)), e1: acc.e1 + cal * @as(i64, @intFromBool(acc.idx == 1)), idx: acc.idx + 1 }
        | no-match |> std/io:print.ln("BAD LINE {{ l:s }}")
    | done _ |> for(0..101)
        ! each a |> captured { best: @max(acc.best, @max(@as(i64, 0), acc.c0 * @as(i64, @intCast(a)) + acc.c1 * (100 - @as(i64, @intCast(a)))) * @max(@as(i64, 0), acc.d0 * @as(i64, @intCast(a)) + acc.d1 * (100 - @as(i64, @intCast(a)))) * @max(@as(i64, 0), acc.f0 * @as(i64, @intCast(a)) + acc.f1 * (100 - @as(i64, @intCast(a)))) * @max(@as(i64, 0), acc.t0 * @as(i64, @intCast(a)) + acc.t1 * (100 - @as(i64, @intCast(a)))) * @as(i64, @intFromBool(acc.e0 * @as(i64, @intCast(a)) + acc.e1 * (100 - @as(i64, @intCast(a))) == 500))) }
        | done |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.best:d }}")
