// AoC 2015 Day 7 Part 1 — wire circuit (statement example: d=72 e=507
// f=492 g=114 h=65412 i=65079). Koru DISPATCHES the gate forms via match;
// storing wires and the memoized recursive eval are leaves.
// Ledger: wire map + memo ← store (gap 2); operand extraction ← groups
// (gap 1); recursive eval ← host (recursion of effectful events is out by
// ruling — this is VALUE recursion, a future subflow question).
// (Part 2 — override wire b, re-eval — is defined against the personal
// puzzle input and has no statement example; runnable form lands when a
// real input is in play.)

import std/io
import std/fs
import std/regex

pub event store { line: []const u8 }

pub event query { w: []const u8 }
| signal i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_071_day07_part1/input.txt")
! line l |> std/regex:match(l)
    | `[a-z0-9]+ -> [a-z]+` _ |> store(line: l)
    | `[a-z0-9]+ AND [a-z0-9]+ -> [a-z]+` _ |> store(line: l)
    | `[a-z0-9]+ OR [a-z0-9]+ -> [a-z]+` _ |> store(line: l)
    | `[a-z0-9]+ LSHIFT [0-9]+ -> [a-z]+` _ |> store(line: l)
    | `[a-z0-9]+ RSHIFT [0-9]+ -> [a-z]+` _ |> store(line: l)
    | `NOT [a-z0-9]+ -> [a-z]+` _ |> store(line: l)
    | no-match |> std/io:print.ln("BAD: {{ l:s }}")
| done _ |> query(w: "d")
    | signal d |> std/io:print.ln("d={{ d:d }}") |> query(w: "e")
        | signal e |> std/io:print.ln("e={{ e:d }}") |> query(w: "f")
            | signal f |> std/io:print.ln("f={{ f:d }}") |> query(w: "g")
                | signal g |> std/io:print.ln("g={{ g:d }}") |> query(w: "h")
                    | signal h |> std/io:print.ln("h={{ h:d }}") |> query(w: "i")
                        | signal i |> std/io:print.ln("i={{ i:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
