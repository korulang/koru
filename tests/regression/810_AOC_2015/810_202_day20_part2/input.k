// AoC 2015 Day 20 Part 1 — lowest house receiving at least the target
// presents (p2 lazy elves ×11, 50-house limit; python-oracled: 6). The UNBOUNDED
// Ledger: hunt loop ← 210_123 panic; divisor sum ← host.

import std/io
import std/fs

pub event presents-check { target: i64, house: i64, lazy: i64 }
| found i64
| next { target: i64, house: i64, lazy: i64 }

capture { goal: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_202_day20_part2/input.txt")
    ! line l |> to-int(s: l)
        | value v |> captured { goal: acc.goal + v }
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured r |> hunt(target: r.goal)
    | house h |> std/io:print.ln("{{ h:d }}")

pub event to-int { s: []const u8 }
| value i64

pub event hunt { target: i64 }
| house i64
