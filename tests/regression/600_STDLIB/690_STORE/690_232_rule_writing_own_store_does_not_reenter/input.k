// PINS: a standing rule that inserts into ITS OWN store — a rule writing its
// own firing condition — fires once per external insert and does not re-enter
// from its own body's write. Same positional standing-enter gate as 690_231:
// the in-body insert never passes `__site_line > <query line>`, so there is
// no rule recursion today. The row the rule mints still lands (`a has 6`).
// For the read/write-set fork this is the self-edge case: a rule whose write
// set intersects its own read set is live in the corpus and terminates only
// because the cascade seam is severed.
import std/io
import std/store

std/store:new(a, capacity: 8) { x: i64 }

std/store:rule(a)
! row e |> std/store:insert(a) { x: e.x + 1 }
    | row _ |> std/io:print.ln("rule inserted {{ e.x:d }} plus one")
    | full |> _

std/store:insert(a) { x: 5 }
| row _ |> _
| full |> _

std/store:query(a)
! query r |> std/io:print.ln("a has {{ r.x:d }}")
