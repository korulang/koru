// AoC 2015 Day 24 Part 1 — balance packages into 3 equal groups; quantum
// entanglement of the smallest front group (statement example → 99). Pure Koru:
// the same bitmask sweep as day17, run twice over the weight list. First the
// total is folded so the per-group target is sum/3. Sweep 1 finds the minimum
// package count among subsets summing to the target (branchless penalty). Sweep
// 2 minimises the quantum entanglement (product of the subset's weights) among
// the subsets at that minimum count — the product is folded branchlessly
// (selected weight, else *1).

import std/io
import std/fs
import std/list
import std/regex

std/list:new(i64)
| list xs |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_241_day24_part1/input.txt")
    ! line l |> std/regex:match(l)
        | `(?<n>[0-9]+)` { n: i64 } |> std/list:push(xs, n)
        | no-match |> _
    | done _ |> std/list:len(xs)
        | len n |> capture { sm: 0[i64] }
            ! as sa |> for(0..n)
                ! each i |> std/list:get(xs, i)
                    | item v |> captured { sm: sa.sm + v }
                    | out-of-bounds |> _
            | captured st |> capture { mn: 999[i64] }
                ! as o1 |> for(0..(@as(usize, 1) << @as(u6, @intCast(n))))
                    ! each mask |> capture { s: 0[i64] }
                        ! as inner |> for(0..n)
                            ! each ix |> std/list:get(xs, ix)
                                | item v2 |> captured { s: inner.s + v2 * @as(i64, @intFromBool((mask >> @as(u6, @intCast(ix))) & 1 == 1)) }
                                | out-of-bounds |> _
                        | captured sub |> captured { mn: @min(o1.mn, @as(i64, @intCast(@popCount(mask))) + @as(i64, @intFromBool(sub.s != @divTrunc(st.sm, 3))) * 999) }
                | captured m1 |> capture { mq: 999999999[i64] }
                    ! as o2 |> for(0..(@as(usize, 1) << @as(u6, @intCast(n))))
                        ! each mask2 |> capture { s2: 0[i64], p: 1[i64] }
                            ! as inner2 |> for(0..n)
                                ! each j |> std/list:get(xs, j)
                                    | item v3 |> captured { s2: inner2.s2 + v3 * @as(i64, @intFromBool((mask2 >> @as(u6, @intCast(j))) & 1 == 1)), p: inner2.p * (v3 * @as(i64, @intFromBool((mask2 >> @as(u6, @intCast(j))) & 1 == 1)) + (1 - @as(i64, @intFromBool((mask2 >> @as(u6, @intCast(j))) & 1 == 1)))) }
                                    | out-of-bounds |> _
                            | captured sub2 |> captured { mq: @min(o2.mq, sub2.p + @as(i64, @intFromBool(sub2.s2 != @divTrunc(st.sm, 3) or @as(i64, @intCast(@popCount(mask2))) != m1.mn)) * 999999999) }
                    | captured result |> std/io:print.ln("{{ result.mq:d }}") |> std/list:free(xs)
    | failed e |> std/io:print.ln("FAILED {{ e:s }}") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
