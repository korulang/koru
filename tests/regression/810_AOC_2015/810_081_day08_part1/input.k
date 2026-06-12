// AoC 2015 Day 8 Part 1 — code chars minus in-memory chars over the four
// statement literals (23 - 11 = 12). PURE .k, EMPTY LEDGER: the escape
// scanner is a STATE MACHINE AS DATA — the state lives in the cell, the
// transition table is an if-tree. st: 0=before-open-quote, 1=in-string,
// 2=after-backslash, 3=after-\x, 4=hex-low, 5=closed.

import std/io
import std/fs

pub event measure { line: []const u8 }
| counted { c: i64, m: i64 }

measure = capture { c: 0[i64], m: 0[i64], st: 0[i64] }
! as a |> for(line)
    ! each ch |> captured { c: a.c + 1 } |> if(a.st == 0)
        | then |> captured { st: 1 }
        | else |> if(a.st == 2)
            | then |> if(ch == 'x')
                | then |> captured { st: 3 }
                | else |> captured { m: a.m + 1, st: 1 }
            | else |> if(a.st == 3)
                | then |> captured { st: 4 }
                | else |> if(a.st == 4)
                    | then |> captured { m: a.m + 1, st: 1 }
                    | else |> if(ch == '\\')
                        | then |> captured { st: 2 }
                        | else |> if(ch == '"')
                            | then |> captured { st: 5 }
                            | else |> captured { m: a.m + 1 }
| captured r => counted { r.c, r.m }

capture { diff: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_081_day08_part1/input.txt")
    ! line l |> measure(line: l)
        | counted { c, m } |> captured { diff: acc.diff + c - m }
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.diff:d }}")
