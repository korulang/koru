// PINS: an owned column fed from another row's PROJECTION must refuse.
// insert into an owned column consumes the caller's <instance!> (690_053's
// contract — ownership moves INTO the store); `r.name` is a borrow off store
// `a`, which keeps owning its instance. Accepting the projection makes two
// stores own one pointer, and both teardowns free it — single ownership is
// the invariant the whole obligation surface rests on, so the write site is
// where this must stop, with the verb and the owned column named.
//
// This is the serialize hole's sharpest edge: rebuilding a store row by row
// (690_124/690_194) reaches owned columns and needs a copying spelling —
// a fresh instance per rebuilt row — because the moving one is refused here.
import std/io
import std/string
import std/store

std/store:new(a, capacity: 2) { name: *std/string:String<instance!> }
std/store:new(b, capacity: 2) { name: *std/string:String<instance!> }

std/string:from-page(text: "x")
| ok s |> std/string:take(s): m |> std/store:insert(a) { name: m }
    | row _ |> _
| err _ |> _

std/store:query(a)
! query r |> std/store:insert(b) { name: r.name }

std/store:query(b)
! query w |> std/string:read(s: w.name): t |> std/io:print.ln("b {{ t:s }}")
