// SUBFLOW-IMPLEMENTED EFFECTS, record-fire wall (pure .k, no proc) — a
// record payload arm is fired with NAMED fields, never positionally.
// `token(1, n)` against `! token { kind: i64, val: i64 }` reads as punning
// and hides which value lands in which field; it must be rejected with a
// wall that spells the named form. (Identity payloads keep the bare single
// value — `pong(x)` — which cannot pun: there is no field name to pun on.)
import std/io

pub event scan { n: i64 }
! token { kind: i64, val: i64 } -> i64
| done i64

scan = token(1, n): t => done t

scan(n: 41)
! token t -> t.kind + t.val
| done r |> std/io:print.ln("{{ r:d }}")
