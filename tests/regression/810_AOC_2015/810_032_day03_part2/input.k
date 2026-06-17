// AoC 2015 Day 3 Part 2 — Robo-Santa: turns alternate between two movers
// sharing one visited set ("^v" → 3, "^>v<" → 3, "^v^v^v^v^v" → 11).
// Parity lives in the cell (t); each direction arm writes its delta then
// the parity-if moves the right actor and visits — write-then-use chains.
// Ledger (shared with part 1): visit/house-count ← collections; classify ← char
// dispatch.

import std/io
import std/fs

pub event visit { x: i64, y: i64 }

pub event house-count {}
| count i64

pub event classify { c: u8 }
| up
| down
| left
| right

pub event walk2 { moves: []const u8 }
| houses i64

walk2 = capture { sx: 0[i64], sy: 0[i64], rx: 0[i64], ry: 0[i64], dx: 0[i64], dy: 0[i64], t: 0[i64] }
! as a |> visit(x: 0, y: 0) |> for(moves)
    ! each c |> classify(c)
        | up |> captured { dx: 0, dy: 1, t: a.t + 1 } |> if(@mod(a.t, 2) == 1)
            | then |> captured { sx: a.sx + a.dx, sy: a.sy + a.dy } |> visit(x: a.sx, y: a.sy)
            | else |> captured { rx: a.rx + a.dx, ry: a.ry + a.dy } |> visit(x: a.rx, y: a.ry)
        | down |> captured { dx: 0, dy: -1, t: a.t + 1 } |> if(@mod(a.t, 2) == 1)
            | then |> captured { sx: a.sx + a.dx, sy: a.sy + a.dy } |> visit(x: a.sx, y: a.sy)
            | else |> captured { rx: a.rx + a.dx, ry: a.ry + a.dy } |> visit(x: a.rx, y: a.ry)
        | left |> captured { dx: -1, dy: 0, t: a.t + 1 } |> if(@mod(a.t, 2) == 1)
            | then |> captured { sx: a.sx + a.dx, sy: a.sy + a.dy } |> visit(x: a.sx, y: a.sy)
            | else |> captured { rx: a.rx + a.dx, ry: a.ry + a.dy } |> visit(x: a.rx, y: a.ry)
        | right |> captured { dx: 1, dy: 0, t: a.t + 1 } |> if(@mod(a.t, 2) == 1)
            | then |> captured { sx: a.sx + a.dx, sy: a.sy + a.dy } |> visit(x: a.sx, y: a.sy)
            | else |> captured { rx: a.rx + a.dx, ry: a.ry + a.dy } |> visit(x: a.rx, y: a.ry)
    | done |> _
| captured _ |> house-count()
    | count n => houses n

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_032_day03_part2/input.txt")
! line m |> walk2(moves: m)
    | houses n |> std/io:print.ln("{{ n:d }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
