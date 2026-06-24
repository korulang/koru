// AoC 2015 Day 14 Part 2 — points race: each second the leading reindeer (all
// tied for max distance) gains a point; the winner has the most points at
// t=1000 (statement: Dancer 689). Pure Koru: parse specs into three parallel
// std/list tables (speed/fly/rest) + a std/map of index→points, then simulate
// per second — find the max distance, award a point to every reindeer at it
// (point delta folded via @intFromBool, no branch). Collections owned at the
// outer scope, borrowed in the loops, freed at the end.
import std/io
import std/fs
import std/regex
import std/list
import std/map

std/list:new(i64)
| list speeds |> std/list:new(i64)
  | list flys |> std/list:new(i64)
    | list rests |> std/map:new()
      | map points |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_142_day14_part2/input.txt")
          ! line l |> std/regex:match(l)
              | `[A-Za-z]+ can fly (?<speed>[0-9]+) km/s for (?<fly>[0-9]+) seconds, but then must rest for (?<rest>[0-9]+) seconds.` { speed: i64, fly: i64, rest: i64 } |> std/list:push(speeds, v: speed) |> std/list:push(flys, v: fly) |> std/list:push(rests, v: rest)
              | no-match |> std/io:print.ln("BAD {{ l:s }}")
          | done _ |> std/list:len(speeds): n |> for(1..1001)
              ! each t |> capture { md: 0[i64] }
                ! as a |> for(0..n)
                    ! each i |> std/list:get(speeds, i)
                        | item sp |> std/list:get(flys, i)
                            | item fl |> std/list:get(rests, i)
                                | item rs |> captured { md: @max(a.md, sp * (@divTrunc(@as(i64, @intCast(t)), fl + rs) * fl + @min(@mod(@as(i64, @intCast(t)), fl + rs), fl))) }
                                | out-of-bounds |> _
                            | out-of-bounds |> _
                        | out-of-bounds |> _
                | captured mres |> for(0..n)
                    ! each j |> std/list:get(speeds, j)
                        | item sp2 |> std/list:get(flys, j)
                            | item fl2 |> std/list:get(rests, j)
                                | item rs2 |> std/map:get(points, k: @as(i64, @intCast(j)))
                                    | value pv |> std/map:set(points, k: @as(i64, @intCast(j)), v: pv + @intFromBool(sp2 * (@divTrunc(@as(i64, @intCast(t)), fl2 + rs2) * fl2 + @min(@mod(@as(i64, @intCast(t)), fl2 + rs2), fl2)) == mres.md))
                                    | missing |> std/map:set(points, k: @as(i64, @intCast(j)), v: @intFromBool(sp2 * (@divTrunc(@as(i64, @intCast(t)), fl2 + rs2) * fl2 + @min(@mod(@as(i64, @intCast(t)), fl2 + rs2), fl2)) == mres.md))
                                | out-of-bounds |> _
                            | out-of-bounds |> _
                        | out-of-bounds |> _
              | done |> capture { mp: 0[i64] }
                ! as b |> for(0..n)
                    ! each k |> std/map:get(points, k: @as(i64, @intCast(k)))
                        | value pv2 |> captured { mp: @max(b.mp, pv2) }
                        | missing |> _
                | captured best |> std/io:print.ln("{{ best.mp:d }}") |> std/list:free(speeds) |> std/list:free(flys) |> std/list:free(rests) |> std/map:free(points)
          | failed e |> std/io:print.ln("FAILED {{ e:s }}") |> std/list:free(speeds) |> std/list:free(flys) |> std/list:free(rests) |> std/map:free(points)
      | err _ |> std/io:print.ln("E4") |> std/list:free(speeds) |> std/list:free(flys) |> std/list:free(rests)
    | err _ |> std/io:print.ln("E3") |> std/list:free(speeds) |> std/list:free(flys)
  | err _ |> std/io:print.ln("E2") |> std/list:free(speeds)
| err _ |> std/io:print.ln("E1")
