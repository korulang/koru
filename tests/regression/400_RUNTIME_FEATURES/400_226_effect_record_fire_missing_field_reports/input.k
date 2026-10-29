// SUBFLOW-IMPLEMENTED EFFECTS, record-fire diagnostics — a fire that supplies
// only SOME declared fields reports the missing one. `pair(a: 1)` leaves
// `b` unsupplied; the KORU022 names the absent field and the full declared
// list. (Sibling: 400_225 pins that an UNKNOWN arg suppresses this loop —
// a misspelled field is not a missing field.)
pub tor calc { n: i64 }
! pair { a: i64, b: i64 }
| done i64

calc = pair(a: 1)
| done => done 0

calc(n: 1)
| done _
