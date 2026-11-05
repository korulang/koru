// The sweep-boundary wall, zip side: a `! each` arm binding read inside
// a NESTED `std/store:query` sweep body cannot cross — the transplant
// sees the bind's arm payload as wildcard `*` and names it untypeable.
// The named refusal (KORU161 + the lift-through-typed-binding teaching
// text) is the wall a14324d59 minted for wildcard-arm binds. RESIDUAL,
// named for a ruling: a DESTRUCTURED bind (`! each { first, _ }`) on
// the same boundary refuses earlier and lies — KORU100 "unused
// binding" — because the use-tracker also cannot see into the sweep
// body; the bind's type IS in the arm's record decl, so whether it
// should cross is open.
import std/io
import std/store
import std/control

std/store:new(rows, capacity: 8) { v: i64 }
std/store:insert(rows) { v: 1 }

std/control:zip(a: 0..2, b: 10..12)
! each p |> std/store:query(rows)
    ! query r |> std/io:print.ln("{{ p.first:d }} on {{ r.v:d }}")
