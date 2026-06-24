// AoC 2015 Day 17 Part 1 — count container subsets summing to 25 (20,15,10,5,5 → 4).
//
// Pure Koru: intake (read-lines → regex-typed → list:push), then count the
// container subsets summing to 25 by a bitmask sweep — outer capture folds the
// count over for(0..2^n), inner capture sums the containers selected by mask's
// bits (320_098 capture-under-non-capture fixed; this exercises capture-under-
// capture too).
import std/io
import std/fs
import std/list
import std/regex

std/list:new(i64)
| list xs |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
    ! line l |> std/regex:match(l)
        | `(?<n>[0-9]+)` { n: i64 } |> std/list:push(xs, n)
        | no-match |> _
    | done _ |> std/list:len(xs): n |> capture { cnt: 0[i64] }
            ! as outer |> for(0..(@as(usize, 1) << @as(u6, @intCast(n))))
                ! each mask |> capture { s: 0[i64] }
                    ! as inner |> for(0..n)
                        ! each i |> std/list:get(xs, i)
                            | item v |> captured { s: inner.s + v * @intFromBool((mask >> @as(u6, @intCast(i))) & 1 == 1) }
                            | out-of-bounds |> _
                    | captured sub |> captured { cnt: outer.cnt + @intFromBool(sub.s == 25) }
            | captured result |> std/io:print.ln("{{ result.cnt:d }}") |> std/list:free(xs)
    | failed e |> std/io:print.ln("FAILED {{ e:s }}") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
