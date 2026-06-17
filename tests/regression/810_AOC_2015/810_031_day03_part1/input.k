// AoC 2015 Day 3 Part 1 — "Perfectly Spherical Houses in a Vacuum"
// (">" → 2, "^>v<" → 4, "^v^v^v^v^v" → 2). PURE .k, CANONICAL SHAPE:
// one walk per input line off disk.
// The .kz ledger owes: classify (wants a char-dispatch surface), and the
// visited SET (visit/house-count — THE collections frontier, votes with
// 320_034/036/038).

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

pub event walk { moves: []const u8 }
| houses i64

walk = capture { x: 0[i64], y: 0[i64] }
! as pos |> visit(x: 0, y: 0) |> for(moves)
    ! each c |> classify(c)
        | up    |> captured { y: pos.y + 1 } |> visit(pos.x, pos.y)
        | down  |> captured { y: pos.y - 1 } |> visit(pos.x, pos.y)
        | left  |> captured { x: pos.x - 1 } |> visit(pos.x, pos.y)
        | right |> captured { x: pos.x + 1 } |> visit(pos.x, pos.y)
| captured _ |> house-count()
    | count n => houses n

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_031_day03_part1/input.txt")
! line m |> walk(moves: m)
    | houses n |> std/io:print.ln("{{ n:d }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
