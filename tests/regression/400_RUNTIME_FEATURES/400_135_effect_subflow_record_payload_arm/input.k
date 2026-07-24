// SUBFLOW-IMPLEMENTED EFFECTS, record resume arm (pure .k, no proc) — the
// subflow sibling of 400_129. A resume arm carries a RECORD payload; the
// proc side switches and field-accesses the union payload; the subflow side
// binds the record at the firing-site branch and field-accesses it in the
// terminal mapping expression (established: `f.file` in 2103, `i.val` in the
// nbody subflows). The consumer constructs the record with the ordinary
// branch-ctor field form (`=> result { ... }`, 400_129 — landed grammar).
import std/io

pub tor request { payload: i64 }
! ask i64 | result { halved: i64, quadrupled: i64 } | timeout
| done i64

request = ask(payload)
| result v => done v.quadrupled + v.halved
| timeout => done 0

request(payload: 20)
! ask n => result { halved: n - 10, quadrupled: n * 4 }
| done r |> std/io:print.ln("{{ r:d }}")
