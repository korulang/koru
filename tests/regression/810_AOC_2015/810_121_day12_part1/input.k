// AoC 2015 Day 12 Part 1 — sum every number in the JSON text (six
// statement examples). PURE .k, EMPTY LEDGER: a char machine accumulates
// digits in the cell. The digit test is ONE condition — `<=` in an if
// condition parses since 210_124 greened (it was eaten at parse before;
// this file carried the nested-if workaround, now collapsed).

import std/io
import std/fs

pub tor sum-numbers { s: string } -> i64

sum-numbers = capture { sum: 0[i64], num: 0[i64], sign: 1[i64], in: 0[i64] }
! as a |> for(s)
    ! each ch |> if(ch >= 48 and ch <= 57)
        | then |> captured { num: a.num * 10 + (ch - 48), in: 1 }
        | else |> if(a.in == 1)
            | then |> captured { sum: a.sum + a.sign * a.num, num: 0, sign: 1, in: 0 } |> if(ch == '-')
                | then |> captured { sign: -1 }
                | else |> _
            | else |> if(ch == '-')
                | then |> captured { sign: -1 }
                | else |> captured { sign: 1 }
| captured r -> (r.sum + r.sign * r.num)

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_121_day12_part1/input.txt")
! line l |> sum-numbers(s: l): t |> std/io:print.ln("{{ t:d }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
