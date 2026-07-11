// AoC 2015 Day 16 Part 2 — RANGED match against the MFCSAM readout: cats/trees
// must read GREATER than the readout, pomeranians/goldfish FEWER, everything else
// exact. Same pure-Koru structure as part 1 (readout string-map built once,
// borrowed per line, freed at read-lines `| done`; capture-fold an all-match
// flag over the split `prop: val` pieces). The only change: a regex on the
// property NAME dispatches the comparison rule — `cats|trees` → v>rv,
// `pomeranians|goldfish` → v<rv, else → v==rv. (Sue 1: cats 8>7, trees 4>3,
// cars 2==2 → match; Sue 2 goldfish 5 not <5; Sue 3 vizslas 1≠0 → 1.)
import std/io
import std/fs
import std/regex
import std/string
import std/string-map

std/string-map:new()
| map m |> std/string-map:set(m, k: "children", v: 3) |> std/string-map:set(m, k: "cats", v: 7) |> std/string-map:set(m, k: "samoyeds", v: 2) |> std/string-map:set(m, k: "pomeranians", v: 3) |> std/string-map:set(m, k: "akitas", v: 0) |> std/string-map:set(m, k: "vizslas", v: 0) |> std/string-map:set(m, k: "goldfish", v: 5) |> std/string-map:set(m, k: "trees", v: 3) |> std/string-map:set(m, k: "cars", v: 2) |> std/string-map:set(m, k: "perfumes", v: 1) |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_162_day16_part2/input.txt")
    ! line l |> std/regex:match(l)
        | `Sue (?<n>[0-9]+): (?<rest>.+)` { n: i64, rest: []const u8 } |> capture { ok: 1[i64], num: n }
            ! as acc |> std/string:split(s: rest, sep: ", ")
                ! piece pc |> std/regex:match(pc)
                    | `(?<p>[a-z]+): (?<v>[0-9]+)` { p: []const u8, v: i64 } |> std/string-map:get(m, k: p)
                        | value rv |> std/regex:match(p)
                            | `cats|trees` _ |> captured { ok: acc.ok * @intFromBool(v > rv) }
                            | `pomeranians|goldfish` _ |> captured { ok: acc.ok * @intFromBool(v < rv) }
                            | no-match |> captured { ok: acc.ok * @intFromBool(v == rv) }
                        | missing |> captured { ok: 0 }
                    | no-match |> captured { ok: 0 }
                | done _ |> _
            | captured result |> if(result.ok == 1)
                | then |> std/io:print.ln("{{ result.num:d }}")
                | else |> _
        | no-match |> _
    | done _ |> std/string-map:free(m)
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| err e |> std/io:print.ln("ERR {{ e:s }}")
