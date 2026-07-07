// AoC 2015 Day 3 Part 2 — Santa + Robo-Santa alternate moves, sharing one
// visited set; count distinct s PER LINE ("^v" → 3, "^>v<" → 3,
// "^v^v^v^v^v" → 11). Pure Koru: a per-line std/set (packed i64 coords), two
// positions in one capture cell, parity (t) selects the active mover via
// ARITHMETIC (no classify, no parity-if): the active santa gets the delta, the
// other gets 0. Both positions are added each turn — the set dedupes, so the
// accumulated keys are exactly the union of s either santa visited.
import std/io
import std/fs
import std/set

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_032_day03_part2/input.txt")
! line m |> std/set:new()
    | set s |> std/set:add(s, v: (0 + 10000) * 100000 + (0 + 10000)) |> capture { sx: 0[i64], sy: 0[i64], rx: 0[i64], ry: 0[i64], t: 0[i64] }
        ! as a |> for(m)
            ! each c |> captured { sx: a.sx + (@as(i64, @intFromBool(c == '>')) - @as(i64, @intFromBool(c == '<'))) * (1 - @mod(a.t, 2)), sy: a.sy + (@as(i64, @intFromBool(c == '^')) - @as(i64, @intFromBool(c == 'v'))) * (1 - @mod(a.t, 2)), rx: a.rx + (@as(i64, @intFromBool(c == '>')) - @as(i64, @intFromBool(c == '<'))) * @mod(a.t, 2), ry: a.ry + (@as(i64, @intFromBool(c == '^')) - @as(i64, @intFromBool(c == 'v'))) * @mod(a.t, 2), t: a.t + 1 } |> std/set:add(s, v: (a.sx + 10000) * 100000 + (a.sy + 10000)) |> std/set:add(s, v: (a.rx + 10000) * 100000 + (a.ry + 10000))
        | captured _ |> std/set:count(s): n |> std/io:print.ln("{{ n:d }}")
    | err e |> std/io:print.ln("ERR {{ e:s }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
