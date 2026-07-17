// AoC 2015 Day 20 Part 1 — lowest house receiving at least the target
// presents (statement table: house 8 gets 150 ≥ 130 → 8). The UNBOUNDED
// HUNT IS KORU — a label fold on the subflow RHS threads (target, house,
// lazy) through payloads, one divisor-sum check per iteration (210_123
// greened; the loop came home). EMPTY LEDGER: the divisor sum is a pure-Koru
// capture-fold over for(1..house+1) (@intFromBool selects divisors, no branch),
// and to-int is the day12 digit-fold; presents-check returns found/next via an
// if-value-return (320_096).

import std/io
import std/fs

pub event presents-check { target: i64, house: i64, lazy: i64 }
| found i64
| next { target: i64, house: i64, lazy: i64 }

pub event hunt { target: i64 } -> i64

presents-check = capture { sum: 0[i64] }
! as a |> for(1..@as(usize, @intCast(house + 1)))
    ! each d |> captured { sum: a.sum + @as(i64, @intCast(d)) * @intFromBool(@mod(house, @as(i64, @intCast(d))) == 0) }
| captured r |> if(r.sum * 10 >= target)
    | then => found house
    | else => next { target, house: house + 1, lazy }

hunt = #h presents-check(target, house: 1, lazy: 0)
| next s |> @h(s.target, s.house, s.lazy)
| found x -> x

capture { goal: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_201_day20_part1/input.txt")
    ! line l |> to-int(s: l)
        | value v |> captured { goal: acc.goal + v }
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured r |> hunt(target: r.goal)
    | house h |> std/io:print.ln("{{ h:d }}")

pub event to-int { s: string } -> i64

to-int = capture { n: 0[i64] }
! as a |> for(s)
    ! each ch |> captured { n: a.n * 10 + (ch - 48) }
| captured r -> r.n
