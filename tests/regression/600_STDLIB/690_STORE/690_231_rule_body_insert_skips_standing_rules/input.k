// PINS: where a standing rule's write CASCADES — and where it does not. An
// insert into `b` performed INSIDE another store's rule body lands in `b`'s
// corpus but does not enter `b`'s standing rules; the same insert at flow
// root does. Mechanism: the standing-enter gate is positional —
// `__site_line > <query line>` (store.kz's "a query subscribes inserts that
// FOLLOW it in source") — and a transplanted qbody's insert is stamped with
// its synthesizer's location, not the body's textual site, so the gate never
// passes. Consequence for the read/write-set fork: a rule's EFFECTIVE
// footprint today is exactly its own body's touches — writes do not
// transitively fire the target store's rules — so a comptime footprint needs
// no cascade closure until this seam changes. `b sees` fires once, for the
// root-position insert only; both rows land.
import std/io
import std/store

std/store:new(a, capacity: 4) { x: i64 }
std/store:new(b, capacity: 8) { y: i64 }

std/store:watch(b)
! row q |> std/io:print.ln("b sees {{ q.y:d }}")

std/store:watch(a)
! row e |> std/store:insert(b) { y: e.x * 2 }
    | row _ |> _
    | full |> _

std/store:insert(a) { x: 5 }
| row _ |> _
| full |> _

std/store:insert(b) { y: 77 }
| row _ |> _
| full |> _

std/store:sweep(b)
! sweep r |> std/io:print.ln("b has {{ r.y:d }}")
