// AoC 2015 Day 13 Part 2 — add yourself at 0 happiness with everyone
// (python-oracled: 286). PURE .k end-to-end: identical to part 1, except YOU
// join the table as one extra seat. You need no table entries at all — an
// absent (a,b) lookup already contributes 0, which is exactly "0 happiness
// with everyone". So part 2 is part 1 with the seat count raised from N to
// N+1; the factorial-base permutation sweep ranges over (N+1)! seatings and
// the extra index (= N) participates with only `missing` lookups.
// Ledger: EMPTY — table ← std collections, permutation search ← pure Koru.

import std/io
import std/fs
import std/regex
import std/string-map
import std/map

std/string-map:new()
| map names |> std/map:new()
    | map happy |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_132_day13_part2/input.txt")
        ! line l |> std/regex:match(l)
            | `(?<a>[A-Za-z]+) would gain (?<amt>[0-9]+) happiness units by sitting next to (?<b>[A-Za-z]+).` { a, amt: i64, b } |> std/string-map:get(names, k: a)
                | value ia |> std/string-map:get(names, k: b)
                    | value ib |> std/map:set(happy, k: ia * 16 + ib, v: amt)
                    | missing |> std/string-map:count(names)
                        | count nb |> std/string-map:set(names, k: b, v: nb) |> std/map:set(happy, k: ia * 16 + nb, v: amt)
                | missing |> std/string-map:count(names)
                    | count na |> std/string-map:set(names, k: a, v: na) |> std/string-map:get(names, k: b)
                        | value ib |> std/map:set(happy, k: na * 16 + ib, v: amt)
                        | missing |> std/string-map:count(names)
                            | count nb |> std/string-map:set(names, k: b, v: nb) |> std/map:set(happy, k: na * 16 + nb, v: amt)
            | `(?<a>[A-Za-z]+) would lose (?<amt>[0-9]+) happiness units by sitting next to (?<b>[A-Za-z]+).` { a, amt: i64, b } |> std/string-map:get(names, k: a)
                | value ia |> std/string-map:get(names, k: b)
                    | value ib |> std/map:set(happy, k: ia * 16 + ib, v: 0 - amt)
                    | missing |> std/string-map:count(names)
                        | count nb |> std/string-map:set(names, k: b, v: nb) |> std/map:set(happy, k: ia * 16 + nb, v: 0 - amt)
                | missing |> std/string-map:count(names)
                    | count na |> std/string-map:set(names, k: a, v: na) |> std/string-map:get(names, k: b)
                        | value ib |> std/map:set(happy, k: na * 16 + ib, v: 0 - amt)
                        | missing |> std/string-map:count(names)
                            | count nb |> std/string-map:set(names, k: b, v: nb) |> std/map:set(happy, k: na * 16 + nb, v: 0 - amt)
            | no-match |> std/io:print.ln("BAD: {{ l:s }}")
        | done _ |> std/string-map:count(names)
            | count n |> capture { fact: 1[i64] }
                ! as fa |> for(1..@as(usize, @intCast(n + 2)))
                    ! each i |> captured { fact: fa.fact * @as(i64, @intCast(i)) }
                | captured ff |> capture { best: -999999999[i64] }
                    ! as bo |> for(0..@as(usize, @intCast(ff.fact)))
                        ! each k |> capture { used: 0[i64], prev: -1[i64], first: -1[i64], cost: 0[i64], rem: ff.fact }
                            ! as pa |> for(0..@as(usize, @intCast(n + 1)))
                                ! each pos |> capture { dig: @mod(@divTrunc(@as(i64, @intCast(k)), @divTrunc(pa.rem, @as(i64, @intCast(n)) + 1 - @as(i64, @intCast(pos)))), @as(i64, @intCast(n)) + 1 - @as(i64, @intCast(pos))), seen: 0[i64], pick: -1[i64] }
                                    ! as sa |> for(0..@as(usize, @intCast(n + 1)))
                                        ! each j |> captured { pick: sa.pick + @as(i64, @intFromBool(sa.pick == -1 and ((pa.used >> @as(u6, @intCast(j))) & 1) == 0 and sa.seen == sa.dig)) * (@as(i64, @intCast(j)) + 1), seen: sa.seen + (1 - ((pa.used >> @as(u6, @intCast(j))) & 1)) }
                                    | captured pk |> std/map:get(happy, k: pa.prev * 16 + pk.pick)
                                        | value fwd |> std/map:get(happy, k: pk.pick * 16 + pa.prev)
                                            | value bwd |> captured { used: pa.used | (@as(i64, 1) << @as(u6, @intCast(pk.pick))), prev: pk.pick, first: pa.first + @as(i64, @intFromBool(pa.first == -1)) * (pk.pick + 1), cost: pa.cost + (fwd + bwd) * @as(i64, @intFromBool(pa.prev >= 0)), rem: @divTrunc(pa.rem, @as(i64, @intCast(n)) + 1 - @as(i64, @intCast(pos))) }
                                            | missing |> captured { used: pa.used | (@as(i64, 1) << @as(u6, @intCast(pk.pick))), prev: pk.pick, first: pa.first + @as(i64, @intFromBool(pa.first == -1)) * (pk.pick + 1), cost: pa.cost, rem: @divTrunc(pa.rem, @as(i64, @intCast(n)) + 1 - @as(i64, @intCast(pos))) }
                                        | missing |> captured { used: pa.used | (@as(i64, 1) << @as(u6, @intCast(pk.pick))), prev: pk.pick, first: pa.first + @as(i64, @intFromBool(pa.first == -1)) * (pk.pick + 1), cost: pa.cost, rem: @divTrunc(pa.rem, @as(i64, @intCast(n)) + 1 - @as(i64, @intCast(pos))) }
                            | captured route |> std/map:get(happy, k: route.prev * 16 + route.first)
                                | value cf |> std/map:get(happy, k: route.first * 16 + route.prev)
                                    | value cb |> captured { best: @max(bo.best, route.cost + cf + cb) }
                                    | missing |> captured { best: @max(bo.best, route.cost + cf) }
                                | missing |> std/map:get(happy, k: route.first * 16 + route.prev)
                                    | value cb |> captured { best: @max(bo.best, route.cost + cb) }
                                    | missing |> captured { best: @max(bo.best, route.cost) }
                    | captured result |> std/io:print.ln("{{ result.best:d }}") |> std/map:free(happy) |> std/string-map:free(names)
        | failed e |> std/io:print.ln("FAILED {{ e:s }}") |> std/map:free(happy) |> std/string-map:free(names)
    | err e |> std/io:print.ln("ERR {{ e:s }}") |> std/string-map:free(names)
| err e |> std/io:print.ln("ERR {{ e:s }}")
