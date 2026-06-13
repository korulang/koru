// AoC 2015 Day 8 Part 1 — ported to use std/switch:char for the two
// char-dispatch sites in the escape scanner. Output must match the original
// if-tree implementation (12).
import std/io
import std/fs
import std/switch

pub event measure { line: []const u8 }
| counted { c: i64, m: i64 }

measure = capture { c: 0[i64], m: 0[i64], st: 0[i64] }
! as a |> for(line)
    ! each ch |> captured { c: a.c + 1 } |> if(a.st == 0)
        | then |> captured { st: 1 }
        | else |> if(a.st == 2)
            | then |> std/switch:char(ch)
                | `x` _ |> captured { st: 3 }
                | no-match |> captured { m: a.m + 1, st: 1 }
            | else |> if(a.st == 3)
                | then |> captured { st: 4 }
                | else |> if(a.st == 4)
                    | then |> captured { m: a.m + 1, st: 1 }
                    | else |> std/switch:char(ch)
                        | `\` _ |> captured { st: 2 }
                        | `"` _ |> captured { st: 5 }
                        | no-match |> captured { m: a.m + 1 }
| captured r => counted { r.c, r.m }

capture { diff: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/600_STDLIB/645_SWITCH/645_004_day08_switch/input.txt")
    ! line l |> measure(line: l)
        | counted { c, m } |> captured { diff: acc.diff + c - m }
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.diff:d }}")
