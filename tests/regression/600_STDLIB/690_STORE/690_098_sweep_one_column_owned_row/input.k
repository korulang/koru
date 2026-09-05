// PINS the shape a sweep arm binds when the store has ONE OWNED column.
//
// Three real programs sweep exactly this store shape — downloads (the curl
// batch), gallery and todo_tui (a one-column owned string) — and until this test
// the corpus pinned none of it. `| item`, `| full` and `! discharge` all hand
// back the VALUE at one owned column (arity picks the payload shape); the sweep
// row is the surface where that rule does NOT reach, so `r.text` is a projection
// off a row binding rather than a field of a record.
//
// Whichever way that settles, it should move by a ruling and a migration, not by
// nobody noticing which one it was.
import std/io
import std/store
import std/string

std/store:new(buf, capacity: 2) { text: *std/string:String<instance!> }

std/string:from-page(text: "alpha")
| ok a |> std/string:take(s: a): m |> std/store:insert(buf) { text: m }
    | row _ |> _
| err _ |> _

std/store:query(buf)
! query r |> std/io:print.ln("row {{ r.text:S }}")
