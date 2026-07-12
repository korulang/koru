// EXPLICIT PIN (Lars 2026-06-13): a SUBFLOW call inside an effect branch is
// legal and exercised on its own — the ! line handler invokes a subflow
// (which itself dispatches a branched event) and handles its terminal.
// Inline lowering must keep subflow invocation + branch dispatch working
// from inside a spliced handler body.

import std/io
import std/fs

pub event shout { s: []const u8 } -> []const u8

shout = upper-stub(s)
| upped u -> u

pub event upper-stub { s: []const u8 } -> []const u8

capture { seen: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/600_STDLIB/650_FS/650_006_subflow_in_effect_branch/input.txt")
    ! line l |> shout(s: l)
        | shouted u |> captured { seen: acc.seen + 1 } |> std/io:print.ln("shout: {{ u:s }}")
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.seen:d }} lines")
