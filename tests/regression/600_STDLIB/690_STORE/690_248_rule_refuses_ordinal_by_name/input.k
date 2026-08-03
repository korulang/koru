// `[ordinal]` ON A RULE ARM IS REFUSED BY NAME, WITH ITS OWN REASON — and the
// reason is the point of this pin, not the refusal.
//
// The request-block gate's clause 1 reads "a request names something the SITE
// knows and the ROW does not". The word is SITE and not VISIT deliberately. A
// standing rule HAS a row and has NO traversal, so:
//
//   [id]      — meaningful. A handle does not depend on a walk. ADMITTED (690_247).
//   [ordinal] — meaningless. There is no position in a walk to name. REFUSED.
//
// A gate phrased around "the VISIT" would collapse *meaningless here* and
// *meaningful but unimplemented here* into one answer, and the author of the
// next request would not be able to tell which they had hit. So the diagnostic
// says so out loud — "this is not unimplemented; it is meaningless here" — and
// points at the arm where `[ordinal]` does belong.
//
// This also replaces a WRONG diagnostic. Before 2026-08-03 any destructure on a
// rule arm was refused as "the retired projection block", which misnames a
// legal construct: a request block is not a projection block (a projection
// listed COLUMNS the body also referenced, said the same thing twice, and let
// the two halves disagree — 690_089). Every entry in a request block is a
// binding and none of them is a column, so nothing is stated twice.
import std/io
import std/store

std/store:new(units, capacity: 64) { hp: i64 }

std/store:rule(units)
! row { [row]e, [ordinal]n } |> std/io:print.ln("hp {{ e.hp:d }} at {{ n:d }}")

std/store:insert(units) { hp: 10 }
