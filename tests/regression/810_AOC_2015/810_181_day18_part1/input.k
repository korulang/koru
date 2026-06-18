// AoC 2015 Day 18 Part 1 — Conway lights, 6x6 statement grid, 4 steps → 4 on.
// Pure Koru, grid THREADED as an [8][8]i64 value (zero-padded border so the
// eight neighbour reads are always in bounds). Each life-step is an event:
// reads the input grid g, writes the next grid into a fresh capture field, and
// returns it as `next`. The 4 steps thread the grid through if-value-return
// recursion (run-steps). Parse fills the padded grid via capture row/col
// counters; count folds the final grid. '#' = 35.

import std/io
import std/fs

pub event life-step { g: [8][8]i64 }
| next [8][8]i64

life-step = capture { h: [8][8]i64{ .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 } } }
! as a |> for(1..7)
    ! each r |> for(1..7)
        ! each c |> captured { h[r][c]: @as(i64, @intFromBool((g[r][c] == 1 and ((g[r - 1][c - 1] + g[r - 1][c] + g[r - 1][c + 1] + g[r][c - 1] + g[r][c + 1] + g[r + 1][c - 1] + g[r + 1][c] + g[r + 1][c + 1]) == 2 or (g[r - 1][c - 1] + g[r - 1][c] + g[r - 1][c + 1] + g[r][c - 1] + g[r][c + 1] + g[r + 1][c - 1] + g[r + 1][c] + g[r + 1][c + 1]) == 3)) or (g[r][c] == 0 and (g[r - 1][c - 1] + g[r - 1][c] + g[r - 1][c + 1] + g[r][c - 1] + g[r][c + 1] + g[r + 1][c - 1] + g[r + 1][c] + g[r + 1][c + 1]) == 3))) }
      | done |> _
  | done |> _
| captured result => next result.h

pub event run-steps { g: [8][8]i64, k: i64 }
| final [8][8]i64

run-steps = if(k >= 4)
| then => final g
| else |> life-step(g)
    | next g2 |> run-steps(g: g2, k: k + 1)
        | final gf => final gf

capture { g: [8][8]i64{ .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0, 0, 0 } }, row: 0[i64], col: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_181_day18_part1/input.txt")
    ! line l |> for(l)
        ! each ch |> captured { g[@as(usize, @intCast(acc.row + 1))][@as(usize, @intCast(acc.col + 1))]: @as(i64, @intFromBool(ch == 35)), col: acc.col + 1 }
      | done |> captured { row: acc.row + 1, col: 0 }
    | done _ |> run-steps(acc.g, k: 0)
        | final gf |> capture { lit: 0[i64] }
            ! as b |> for(0..8)
                ! each rr |> for(0..8)
                    ! each cc |> captured { lit: b.lit + gf[rr][cc] }
                  | done |> _
              | done |> _
            | captured cres |> std/io:print.ln("{{ cres.lit:d }}")
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured _ |> _
