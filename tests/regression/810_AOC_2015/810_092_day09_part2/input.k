// AoC 2015 Day 9 Part 2 — LONGEST route visiting every city once
// (statement example: London/Dublin/Belfast → 982). PURE .k end-to-end:
// names are interned to indices in a std/string-map, the symmetric distance
// table is a std/map keyed by (a*16 + b), and the PERMUTATION SEARCH is a
// pure-Koru factorial-base sweep — for k in 0..N! a nested capture-fold
// decodes the Lehmer code (pick the dig-th still-unused index per position),
// sums the open-route cost, and folds the MAXIMUM. No host recursion: the
// same data-dependent sweep shape proven by the day17/24 bitmask subset
// folds, with a factorial decode in place of bit extraction.
// Ledger: EMPTY — table ← std collections, permutation search ← pure Koru.

import std/io
import std/fs
import std/regex
import std/string-map
import std/map

std/string-map:new()
| map names |> std/map:new()
    | map dist |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_092_day09_part2/input.txt")
        ! line l |> std/regex:match(l)
            | `(?<a>[A-Za-z]+) to (?<b>[A-Za-z]+) = (?<d>[0-9]+)` { a, b, d: i64 } |> std/string-map:get(m: names, k: a)
                | value ia |> std/string-map:get(m: names, k: b)
                    | value ib |> std/map:set(m: dist, k: ia * 16 + ib, v: d) |> std/map:set(m: dist, k: ib * 16 + ia, v: d)
                    | missing |> std/string-map:count(m: names): nb |> std/string-map:set(m: names, k: b, v: nb) |> std/map:set(m: dist, k: ia * 16 + nb, v: d) |> std/map:set(m: dist, k: nb * 16 + ia, v: d)
                | missing |> std/string-map:count(m: names): na |> std/string-map:set(m: names, k: a, v: na) |> std/string-map:get(m: names, k: b)
                        | value ib |> std/map:set(m: dist, k: na * 16 + ib, v: d) |> std/map:set(m: dist, k: ib * 16 + na, v: d)
                        | missing |> std/string-map:count(m: names): nb |> std/string-map:set(m: names, k: b, v: nb) |> std/map:set(m: dist, k: na * 16 + nb, v: d) |> std/map:set(m: dist, k: nb * 16 + na, v: d)
            | no-match |> std/io:print.ln("BAD: {{ l:s }}")
        | done _ |> std/string-map:count(m: names): n |> capture { fact: 1[i64] }
                ! as fa |> for(1..@as(usize, @intCast(n + 1)))
                    ! each i |> captured { fact: fa.fact * @as(i64, @intCast(i)) }
                | captured ff |> capture { best: -1[i64] }
                    ! as bo |> for(0..@as(usize, @intCast(ff.fact)))
                        ! each k |> capture { used: 0[i64], prev: -1[i64], cost: 0[i64], rem: ff.fact }
                            ! as pa |> for(0..@as(usize, @intCast(n)))
                                ! each pos |> capture { dig: @mod(@divTrunc(@as(i64, @intCast(k)), @divTrunc(pa.rem, @as(i64, @intCast(n)) - @as(i64, @intCast(pos)))), @as(i64, @intCast(n)) - @as(i64, @intCast(pos))), seen: 0[i64], pick: -1[i64] }
                                    ! as sa |> for(0..@as(usize, @intCast(n)))
                                        ! each j |> captured { pick: sa.pick + @as(i64, @intFromBool(sa.pick == -1 and ((pa.used >> @as(u6, @intCast(j))) & 1) == 0 and sa.seen == sa.dig)) * (@as(i64, @intCast(j)) + 1), seen: sa.seen + (1 - ((pa.used >> @as(u6, @intCast(j))) & 1)) }
                                    | captured pk |> std/map:get(m: dist, k: pa.prev * 16 + pk.pick)
                                        | value edge |> captured { used: pa.used | (@as(i64, 1) << @as(u6, @intCast(pk.pick))), prev: pk.pick, cost: pa.cost + edge * @as(i64, @intFromBool(pa.prev >= 0)), rem: @divTrunc(pa.rem, @as(i64, @intCast(n)) - @as(i64, @intCast(pos))) }
                                        | missing |> captured { used: pa.used | (@as(i64, 1) << @as(u6, @intCast(pk.pick))), prev: pk.pick, pa.cost, rem: @divTrunc(pa.rem, @as(i64, @intCast(n)) - @as(i64, @intCast(pos))) }
                            | captured route |> captured { best: @max(bo.best, route.cost) }
                    | captured result |> std/io:print.ln("{{ result.best:d }}") |> std/map:free(m: dist) |> std/string-map:free(m: names)
        | failed e |> std/io:print.ln("FAILED {{ e:s }}") |> std/map:free(m: dist) |> std/string-map:free(m: names)
    | err e |> std/io:print.ln("ERR {{ e:s }}") |> std/string-map:free(m: names)
| err e |> std/io:print.ln("ERR {{ e:s }}")
