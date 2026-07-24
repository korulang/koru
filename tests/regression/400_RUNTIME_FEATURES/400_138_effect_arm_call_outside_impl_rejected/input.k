// SUBFLOW-IMPLEMENTED EFFECTS, the ownership wall (pure .k, no proc) — only
// the declaring event's own implementation may fire its arms. Here a SECOND
// event's impl calls `pong`, which is ping's effect arm, not an event. That
// must be rejected — and with a GUIDING diagnostic naming the owner, not a
// bare "unknown event": firing from outside the impl is an understandable
// mistake, and the wall should point at the rule that was broken.
import std/io

pub tor ping { x: i64 }
! pong i64

ping = pong(x)

pub tor other { x: i64 }
! stray i64

other = pong(x)

ping(x: 41)
! pong reply |> std/io:print.ln("{{ reply + 1:d }}")
