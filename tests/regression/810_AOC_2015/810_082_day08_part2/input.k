// AoC 2015 Day 8 Part 2 — re-encoded length minus code length over the
// four statement literals (42 - 23 = 19). PURE .k, EMPTY LEDGER: each
// code char costs 2 when it is a quote or backslash, else 1, plus 2 new
// surrounding quotes per line.

import std/io
import std/fs

pub tor measure { line: string } -> { c: i64, e: i64 }

measure = capture { c: 0[i64], e: 2[i64] }
! as a |> for(line)
    ! each ch |> captured { c: a.c + 1 } |> if(ch == '"' or ch == '\\')
        | then |> captured { e: a.e + 2 }
        | else |> captured { e: a.e + 1 }
| captured r -> { r.c, r.e }

capture { diff: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_082_day08_part2/input.txt")
    ! line l |> measure(line: l): counted |> captured { diff: acc.diff + counted.e - counted.c }
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.diff:d }}")
