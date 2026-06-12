// AoC 2015 Day 14 Part 1 — reindeer race, max distance at t=1000
// (statement: Comet 1120, Dancer 1056 → 1120). PURE .k since 2026-06-12:
// parse-reindeer retired by regex NAMED GROUPS — the sentence form IS the
// pattern, three typed fields convert at the splice, and the distance
// formula stays where it always was: Koru expressions. Ledger is empty.

import std/io
import std/fs
import std/regex

capture { best: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_141_day14_part1/input.txt")
    ! line l |> std/regex:match(l)
        | `[A-Za-z]+ can fly (?<speed>[0-9]+) km/s for (?<fly>[0-9]+) seconds, but then must rest for (?<rest>[0-9]+) seconds.` { speed: i64, fly: i64, rest: i64 } |> captured {
            best: @max(acc.best, speed * (@divTrunc(1000, fly + rest) * fly + @min(@mod(1000, fly + rest), fly)))
        }
        | no-match |> std/io:print.ln("BAD LINE {{ l:s }}")
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.best:d }}")
