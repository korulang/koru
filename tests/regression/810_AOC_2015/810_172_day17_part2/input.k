// AoC 2015 Day 17 Part 2 — ways to fill the MINIMUM number of containers that
// sum to 25 (20,15,10,5,5 → the minimum is 2 containers, and there are 3 such
// ways). Pure Koru: the same bitmask sweep as part 1, run twice. Sweep 1 finds
// the minimum container count among valid subsets (branchless — an invalid mask
// adds a huge penalty so it can never win the @min). Sweep 2 counts the valid
// subsets whose popcount equals that minimum.
import std/io
import std/fs
import std/list
import std/regex

std/list:new(i64)
| list xs |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_172_day17_part2/input.txt")
    ! line l |> std/regex:match(l)
        | `(?<n>[0-9]+)` { n: i64 } |> std/list:push(xs, v: n)
        | no-match |> _
    | done _ |> std/list:len(xs): n |> capture { mn: 999[i64] }
            ! as o1 |> for(0..(@as(usize, 1) << @as(u6, @intCast(n))))
                ! each mask |> capture { s: 0[i64] }
                    ! as inner |> for(0..n)
                        ! each i |> std/list:get(xs, i)
                            | item v |> captured { s: inner.s + v * @intFromBool((mask >> @as(u6, @intCast(i))) & 1 == 1) }
                            | out-of-bounds |> _
                    | captured sub |> captured { mn: @min(o1.mn, @as(i64, @intCast(@popCount(mask))) + @as(i64, @intFromBool(sub.s != 25)) * 999) }
            | captured m1 |> capture { cnt: 0[i64] }
                ! as o2 |> for(0..(@as(usize, 1) << @as(u6, @intCast(n))))
                    ! each mask2 |> capture { s2: 0[i64] }
                        ! as inner2 |> for(0..n)
                            ! each j |> std/list:get(xs, i: j)
                                | item v2 |> captured { s2: inner2.s2 + v2 * @intFromBool((mask2 >> @as(u6, @intCast(j))) & 1 == 1) }
                                | out-of-bounds |> _
                        | captured sub2 |> captured { cnt: o2.cnt + @intFromBool(sub2.s2 == 25 and @as(i64, @intCast(@popCount(mask2))) == m1.mn) }
                | captured result |> std/io:print.ln("{{ result.cnt:d }}") |> std/list:free(xs)
    | failed e |> std/io:print.ln("FAILED {{ e:s }}") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
