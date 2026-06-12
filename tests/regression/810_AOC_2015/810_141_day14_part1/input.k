// AoC 2015 Day 14 Part 1 — reindeer race, max distance at t=1000
// (statement: Comet 1120, Dancer 1056 → 1120). The DISTANCE FORMULA lives
// in Koru expressions over the destructured spec; only the sentence parse
// is a leaf. Ledger: parse-reindeer ← groups.

import std/io
import std/fs

pub event parse-reindeer { line: []const u8 }
| spec { speed: i64, fly: i64, rest: i64 }

capture { best: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_141_day14_part1/input.txt")
    ! line l |> parse-reindeer(line: l)
        | spec { speed, fly, rest } |> captured {
            best: @max(acc.best, speed * (@divTrunc(1000, fly + rest) * fly + @min(@mod(1000, fly + rest), fly)))
        }
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.best:d }}")
