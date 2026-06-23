// AoC 2015 Day 3 Part 1 — houses visited at least once, PER LINE (each line is
// an independent walk: ">" → 2, "^>v<" → 4, "^v^v^v^v^v" → 2). Pure Koru: per
// line a fresh std/set of visited houses (2D coord packed into one i64 key — the
// sanctioned set idiom), position in a capture cell, each move folded as
// arithmetic on the char (dx = '>'-'<', dy = '^'-'v'; no classify branch). The
// per-line <set!> is auto-discharged after the count (the capture-under-set
// obligation pattern, 660_019).
import std/io
import std/fs
import std/set

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_031_day03_part1/input.txt")
! line m |> std/set:new()
    | set houses |> std/set:add(houses, v: (0 + 10000) * 100000 + (0 + 10000)) |> capture { x: 0[i64], y: 0[i64] }
        ! as pos |> for(m)
            ! each c |> captured { x: pos.x + @as(i64, @intFromBool(c == '>')) - @as(i64, @intFromBool(c == '<')), y: pos.y + @as(i64, @intFromBool(c == '^')) - @as(i64, @intFromBool(c == 'v')) } |> std/set:add(houses, v: (pos.x + 10000) * 100000 + (pos.y + 10000))
        | captured _ |> std/set:count(houses): n |> std/io:print.ln("{{ n:d }}")
    | err e |> std/io:print.ln("ERR {{ e:s }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
