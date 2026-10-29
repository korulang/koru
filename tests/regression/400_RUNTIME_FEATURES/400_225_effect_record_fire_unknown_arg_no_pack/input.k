// SUBFLOW-IMPLEMENTED EFFECTS, record-fire diagnostics — one malformed fire
// produces ONE diagnostic. `pair(wrong: 1)` names a field the record payload
// does not declare; the KORU021 that refuses it already lists every declared
// field. Per-field "missing at the firing site" reports on top would pack a
// single fault into N reports — and each is speculative, since `wrong` may be
// a misspelling of the very field it claims absent. (Sibling: 400_140 pins
// the positional-fire wall on the same check.)
pub tor calc { n: i64 }
! pair { a: i64, b: i64 }
| done i64

calc = pair(wrong: 1)
| done => done 0

calc(n: 1)
| done _
