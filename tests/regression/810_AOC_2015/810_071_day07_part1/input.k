// AoC 2015 Day 7 Part 1 — wire circuit (statement example: d=72 e=507
// f=492 g=114 h=65412 i=65079). Koru DISPATCHES the gate forms via match;
// the gate-form dispatch (below) and operand extraction (groups) are green
// idioms. Two gaps hold it RED:
//
//   1. STRUCTURED, STRING-KEYED STORE (the wire table). Each wire maps its
//      NAME → a gate rule (op + up to two operands, each a literal OR another
//      wire name). koru_std/string-map is string→i64 ONLY; there is no
//      string-keyed store for a structured rule (a small record, or parallel
//      maps op/lhs/rhs/lhs-is-wire/...). So the rules can be parsed and
//      dispatched, but not STORED keyed by wire name for later lookup.
//
//   2. OBLIGATION THREADING of that store through the recursive eval. The
//      ledger's old note ("recursive eval ← host / value recursion out by
//      ruling") is now STALE: value recursion of events IS available
//      (320_095, green — an event calling itself). The real blocker is that
//      `query` would have to RANDOM-ACCESS the wire store inside its own
//      recursion, i.e. carry the owned store-handle as a parameter — which
//      trips the SAME phantom gap that holds day 22 (810_221) and day 10
//      (810_101) RED:
//
//        error[KORU030]: Phantom state mismatch: expected 'input:<state>' but
//          got 'std.<mod>:<state>!' for argument '<store>'
//
//      A user-event parameter's phantom state is namespaced to the user module
//      ('input:'), and that does not unify with the std-collection-namespaced
//      state the live handle carries ('std.list:'/'std.string-map:'), so an
//      owned collection cannot be passed to a user event or threaded through a
//      recursion/fold payload. Design-shaped (ownership transfer of a
//      phantom-obligation resource across user-event params and recursion), not
//      a missing leaf. Left RED honestly pending both pieces.
//
// (Part 2 — override wire b, re-eval — is defined against the personal
// puzzle input and has no statement example; runnable form lands when a
// real input is in play.)

import std/io
import std/fs
import std/regex

pub event collect { line: string }

pub event query { w: string }
| signal i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_071_day07_part1/input.txt")
! line l |> std/regex:match(l)
    | `[a-z0-9]+ -> [a-z]+` _ |> collect(line: l)
    | `[a-z0-9]+ AND [a-z0-9]+ -> [a-z]+` _ |> collect(line: l)
    | `[a-z0-9]+ OR [a-z0-9]+ -> [a-z]+` _ |> collect(line: l)
    | `[a-z0-9]+ LSHIFT [0-9]+ -> [a-z]+` _ |> collect(line: l)
    | `[a-z0-9]+ RSHIFT [0-9]+ -> [a-z]+` _ |> collect(line: l)
    | `NOT [a-z0-9]+ -> [a-z]+` _ |> collect(line: l)
    | no-match |> std/io:print.ln("BAD: {{ l:s }}")
| done _ |> query(w: "d")
    | signal d |> std/io:print.ln("d={{ d:d }}") |> query(w: "e")
        | signal e |> std/io:print.ln("e={{ e:d }}") |> query(w: "f")
            | signal f |> std/io:print.ln("f={{ f:d }}") |> query(w: "g")
                | signal g |> std/io:print.ln("g={{ g:d }}") |> query(w: "h")
                    | signal h |> std/io:print.ln("h={{ h:d }}") |> query(w: "i")
                        | signal i |> std/io:print.ln("i={{ i:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
