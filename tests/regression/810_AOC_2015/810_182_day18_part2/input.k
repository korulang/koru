// AoC 2015 Day 18 Part 2 — Conway lights with the four CORNERS stuck on, 6x6
// grid, 5 steps → 17. Same threaded [8][8] design as part 1. The corners (padded
// coords (1,1),(1,6),(6,1),(6,6)) are forced on: seeded after parse and re-forced
// in every step's output via @max(conway, is-corner). 5 steps via run-steps.

import std/io
import std/fs

pub tor life-step { g: [8][8]i64 } -> [8][8]i64

life-step = capture { h: [8][8]i64{ .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 } } }
! as a |> for(1..7)
    ! each r |> for(1..7)
        ! each c |> captured { h[r][c]: @max(@as(i64, @intFromBool((g[r][c] == 1 and ((g[r - 1][c - 1] + g[r - 1][c] + g[r - 1][c + 1] + g[r][c - 1] + g[r][c + 1] + g[r + 1][c - 1] + g[r + 1][c] + g[r + 1][c + 1]) == 2 or (g[r - 1][c - 1] + g[r - 1][c] + g[r - 1][c + 1] + g[r][c - 1] + g[r][c + 1] + g[r + 1][c - 1] + g[r + 1][c] + g[r + 1][c + 1]) == 3)) or (g[r][c] == 0 and (g[r - 1][c - 1] + g[r - 1][c] + g[r - 1][c + 1] + g[r][c - 1] + g[r][c + 1] + g[r + 1][c - 1] + g[r + 1][c] + g[r + 1][c + 1]) == 3))), @as(i64, @intFromBool((r == 1 or r == 6) and (c == 1 or c == 6)))) }
      | done |> _
  | done |> _
| captured result -> result.h

pub tor run-steps { g: [8][8]i64, k: i64 } -> [8][8]i64

run-steps = if(k >= 5)
| then -> g
| else |> life-step(g)
    | next g2 |> run-steps(g: g2, k: k + 1)
        | final gf -> gf

capture { g: [8][8]i64{ .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 } }, row: 0[i64], col: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_182_day18_part2/input.txt")
    ! line l |> for(l)
        ! each ch |> captured { g[@as(usize, @intCast(acc.row + 1))][@as(usize, @intCast(acc.col + 1))]: @as(i64, @intFromBool(ch == 35)), col: acc.col + 1 }
      | done |> captured { row: acc.row + 1, col: 0 }
    | done _ |> captured { g[1][1]: 1, g[1][6]: 1, g[6][1]: 1, g[6][6]: 1 } |> run-steps(acc.g, k: 0)
        | final gf |> capture { lit: 0[i64] }
            ! as b |> for(0..8)
                ! each rr |> for(0..8)
                    ! each cc |> captured { lit: b.lit + gf[rr][cc] }
                  | done |> _
              | done |> _
            | captured cres |> std/io:print.ln("{{ cres.lit:d }}")
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured _ |> _
