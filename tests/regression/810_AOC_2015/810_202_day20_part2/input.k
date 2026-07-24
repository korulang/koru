// AoC 2015 Day 20 Part 2 — lazy elves: ×11 presents, each elf stops
// after 50 houses (python-oracled: target 130 → house 6). The UNBOUNDED
// HUNT IS KORU — the same label fold as part 1 with lazy: 1 (210_123
// greened; the loop came home). EMPTY LEDGER: presents-check is a pure-Koru
// capture-fold — an elf e delivers to house n only while n/e <= 50, so the
// divisor d counts iff d|house AND house/d <= 50 (×11 presents). to-int is the
// day12 digit-fold; found/next via if-value-return (320_096).

import std/io
import std/fs

pub tor presents-check { target: i64, house: i64, lazy: i64 }
| found i64
| next { target: i64, house: i64, lazy: i64 }

pub tor hunt { target: i64 } -> i64

presents-check = capture { sum: 0[i64] }
! as a |> for(1..@as(usize, @intCast(house + 1)))
    ! each d |> captured { sum: a.sum + @as(i64, @intCast(d)) * @intFromBool(@mod(house, @as(i64, @intCast(d))) == 0 and @divTrunc(house, @as(i64, @intCast(d))) <= 50) }
| captured r |> if(r.sum * 11 >= target)
    | then => found house
    | else => next { target, house: house + 1, lazy }

hunt = #h presents-check(target, house: 1, lazy: 1)
| next s |> @h(s.target, s.house, s.lazy)
| found x -> x

capture { goal: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_202_day20_part2/input.txt")
    ! line l |> to-int(s: l)
        | value v |> captured { goal: acc.goal + v }
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured r |> hunt(target: r.goal)
    | house h |> std/io:print.ln("{{ h:d }}")

pub tor to-int { s: string } -> i64

to-int = capture { n: 0[i64] }
! as a |> for(s)
    ! each ch |> captured { n: a.n * 10 + (ch - 48) }
| captured r -> r.n
