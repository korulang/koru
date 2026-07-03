// MUST_FAIL — presence-testing a REQUIRED arm. Designed 2026-07-03: the
// presence expression (`if(pong)` / `when pong`) exists because OPTIONAL
// handlers may be absent. A required arm is always installed — the
// exhaustiveness check guarantees it — so testing for it is a meaningless
// always-true and almost certainly a misread of the contract. Reject it
// and say why, rather than folding to `true` silently.
import std/io

pub event ping { x: i64 }
! pong i64

ping = if(pong)
| then |> pong(x)
| else |> pong(0)

ping(x: 41)
! pong v |> std/io:print.ln("{{ v:d }}")
