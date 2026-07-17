// AoC 2015 Day 1 Part 2 — position (1-based) of the first char that takes
// Santa into the basement (floor -1). Canonical statement examples:
// ")" → 1, "()())" → 5. One answer per input line.
// No early-exit needed: the cell records the position once (pos stays 0
// until the basement first happens) — found-state as data, not control.

import std/io
import std/fs

pub event basement-pos { moves: string } -> i64

basement-pos = capture { floor: 0[i64], idx: 0[i64], pos: 0[i64] }
! as acc |> for(moves)
    ! each c |> captured { idx: acc.idx + 1 } |> if(c == '(')
        | then |> captured { floor: acc.floor + 1 }
        | else |> captured { floor: acc.floor - 1 } |> if(acc.floor == -1 and acc.pos == 0)
            | then |> captured { pos: acc.idx }
            | else |> _
| captured r -> r.pos

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_012_day01_part2/input.txt")
! line l |> basement-pos(moves: l)
    | at p |> std/io:print.ln("{{ p:d }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
