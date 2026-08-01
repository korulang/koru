// The control for 690_096's cascade guard: suppression must be NARROW.
//
// 690_096 made a site stay silent when the store's own `std/store:new` was
// already refused, so one mistake stops producing N diagnostics. The way that
// fix goes wrong is by suppressing too much — and the trap is specific: a
// downstream refusal's own text reads "unknown store 'typo' - no
// std/store:new(typo) found". It CONTAINS the declaration's spelling. A
// substring test would let the first ghost silence the second, and a real typo
// would go quiet the moment anything else complained about it.
//
// Nothing here is refused at its declaration — `typo` was simply never declared.
// Both sites must say so, independently.
import std/io
import std/store

std/store:new(real, capacity: 2) { v: i64 }

std/store:insert(typo) { v: 1 }
| row _ |> _

std/store:query(typo)
! query r |> std/io:print.ln("v {{ r.v:d }}")
