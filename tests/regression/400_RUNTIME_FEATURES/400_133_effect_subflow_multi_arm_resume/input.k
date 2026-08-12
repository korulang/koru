// SUBFLOW-IMPLEMENTED EFFECTS, multi-arm resume (pure .k, no proc) — the
// subflow sibling of 400_114, completing the full-return symmetry in Koru.
// The proc side consumes the resume sum as a synthesized tagged union and a
// Zig `switch`; the subflow side consumes it as BRANCHES at the firing site,
// each mapped to a terminal with the established `=>` branch mapping — the
// impl body is exactly 240's shape (`run = step() | return => stopped ...`),
// with the head call being the event's own `ask` arm.
//
// Consumer side is already-landed grammar: `=> halved ...` selects a resume
// arm (400_114), so this test's red is entirely the impl side.
import std/io

pub tor request { payload: i64 }
! ask i64
    | halved i64
    | timeout
| done i64

request = ask(payload)
| halved v => done v
| timeout => done 0

request(payload: 20)
! ask n => halved n - 10
| done r |> std/io:print.ln("{{ r:d }}")
