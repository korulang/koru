// AoC 2015 Day 16 Part 1 — which Sue matches the MFCSAM readout (exact match on
// every listed property). Built in pure Koru: the readout is a std/string-map
// (built once, borrowed per line, freed at read-lines `| done` — the canonical
// obligation-under-effect-loop pattern). Each line: regex-capture `Sue N: rest`,
// split the rest into `prop: val` pieces, match each piece, look the property up
// in the readout, and fold an all-match flag (ok stays 1 only if every listed
// property equals the readout). A matching Sue prints its number. (Sue 1 cats=8
// vs 7 ✗, Sue 2 all match ✓, Sue 3 vizslas=1 vs 0 ✗ → 2.)
import std/io
import std/fs
import std/regex
import std/string
import std/string-map

std/string-map:new()
| map m |> std/string-map:set(m, k: "children", v: 3) |> std/string-map:set(m, k: "cats", v: 7) |> std/string-map:set(m, k: "samoyeds", v: 2) |> std/string-map:set(m, k: "pomeranians", v: 3) |> std/string-map:set(m, k: "akitas", v: 0) |> std/string-map:set(m, k: "vizslas", v: 0) |> std/string-map:set(m, k: "goldfish", v: 5) |> std/string-map:set(m, k: "trees", v: 3) |> std/string-map:set(m, k: "cars", v: 2) |> std/string-map:set(m, k: "perfumes", v: 1) |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_161_day16_part1/input.txt")
    ! line l |> std/regex:match(l)
        | `Sue (?<n>[0-9]+): (?<rest>.+)` { n: i64, rest: string } |> capture { ok: 1[i64], num: n }
            ! as acc |> std/string:split(s: rest, sep: ", ")
                ! piece pc |> std/regex:match(pc)
                    | `(?<p>[a-z]+): (?<v>[0-9]+)` { p: string, v: i64 } |> std/string-map:get(m, k: p)
                        | value rv |> captured { ok: acc.ok * @intFromBool(rv == v) }
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
