// PROBE 3: two string predicates via per-char iteration (no regex).
// (a) a two-adjacent-char pair repeats without overlapping (delayed-insert
//     into a std/set: by the time pair (p1,c) at position i is checked, the
//     set holds every pair up through position i-2 — never the immediately
//     overlapping pair at i-1).
// (b) a char repeats with exactly one char between (p2 == c), arithmetic-only
//     via @intFromBool/@max — no branch needed.
// Grounded on: per-char `for(s)` + host char arithmetic —
//   tests/regression/810_AOC_2015/810_031_day03_part1/input.k
//   tests/regression/810_AOC_2015/810_111_day11_part1/input.k (to-n event)
// std/set add/contains/free — tests/regression/600_STDLIB/660_COLLECTIONS/660_018_set_dedup_count/input.k
// multi-field capture under a set obligation — .../660_020_set_under_capture_loop/input.k
import std/io
import std/set

pub event check { s: []const u8 }

check = std/set:new()
| set seen |> capture { p2: -1[i64], p1: -1[i64], found_pair: 0[i64], found_gap: 0[i64] }
    ! as st |> for(s)
        ! each c |> std/set:add(seen, v: st.p2 * 256 + st.p1) |> std/set:contains(seen, v: st.p1 * 256 + @as(i64, c))
            | yes |> captured { found_pair: 1, found_gap: @max(st.found_gap, @intFromBool(st.p2 == @as(i64, c))), p2: st.p1, p1: @as(i64, c) }
            | no |> captured { found_pair: st.found_pair, found_gap: @max(st.found_gap, @intFromBool(st.p2 == @as(i64, c))), p2: st.p1, p1: @as(i64, c) }
    | captured r |> std/set:free(seen) |> std/io:print.ln("pair={{ r.found_pair:d }} gap={{ r.found_gap:d }}")
| err e |> std/io:print.ln("ERR {{ e:s }}")

check(s: "qjhvhtzxzqqjkmpb")
check(s: "xxyxx")
check(s: "uurcxstgmygtbstg")
check(s: "ieodomkazucvgmuy")
