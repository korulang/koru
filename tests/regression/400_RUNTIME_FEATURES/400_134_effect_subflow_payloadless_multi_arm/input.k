// SUBFLOW-IMPLEMENTED EFFECTS, payloadless multi-arm (pure .k, no proc) —
// the subflow sibling of 400_128. The yield carries nothing (spelled by
// OMISSION, `! ask | ...`, never a unit token — 210_137); the impl fires it
// with a bare positional call `ask()` (the proc does the same) and consumes
// the resume sum as branches mapped to terminals, 240-style.
import std/io

pub event request { payload: i64 }
! ask | halved i64 | timeout
| done i64

request = ask()
| halved v => done v
| timeout => done 0

request(payload: 20)
! ask => halved 7
| done r |> std/io:print.ln("{{ r:d }}")
