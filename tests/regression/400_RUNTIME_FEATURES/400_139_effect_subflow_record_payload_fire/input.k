// SUBFLOW-IMPLEMENTED EFFECTS, record yield payload fired with NAMED fields
// (pure .k, no proc) — the producer-side sibling of 400_079 (whose record
// payload is fired from Zig as an anon struct). Ruled 2026-07-02: firing
// follows the BRANCH convention — an identity payload takes one bare value
// (`pong(x)`, `=> done n`'s call-twin), a RECORD payload takes NAMED fields
// (`token(kind: 1, val: n)`, `=> result { ... }`'s call-twin). The event
// declaration sits three lines above the fire, so the names read against
// their contract in place.
//
// Consumer side is established grammar: record yield bound whole (`! token t`,
// 400_079) with a `->` resume producer (`! v { ... } -> u64`, 400_118).
import std/io

pub event scan { n: i64 }
! token { kind: i64, val: i64 } -> i64
| done i64

scan = token(kind: 1, val: n): t => done t

scan(n: 41)
! token t -> t.kind + t.val
| done r |> std/io:print.ln("{{ r:d }}")
