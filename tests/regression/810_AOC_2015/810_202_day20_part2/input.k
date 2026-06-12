// AoC 2015 Day 20 Part 2 — lazy elves: ×11 presents, each elf stops
// after 50 houses (python-oracled: target 130 → house 6). The UNBOUNDED
// HUNT IS KORU — the same label fold as part 1 with lazy: 1 (210_123
// greened; the loop came home). Ledger: divisor sum ← host;
// to-int ← string-ops/typed-groups.

import std/io
import std/fs

pub event presents-check { target: i64, house: i64, lazy: i64 }
| found i64
| next { target: i64, house: i64, lazy: i64 }

pub event hunt { target: i64 }
| house i64

hunt = #h presents-check(target, house: 1, lazy: 1)
| next s |> @h(s.target, s.house, s.lazy)
| found x => house x

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
