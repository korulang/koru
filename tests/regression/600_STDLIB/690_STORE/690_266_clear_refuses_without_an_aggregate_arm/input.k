// PINS: `clear` refuses a store whose observer would silently stop being told.
//
// A `! removed` arm is a per-row observer. `clear` does not fire it — firing
// it once per row is exactly the cost `clear` exists to remove — so a store
// carrying one must also declare `! cleared` to say what emptying means for
// its observers. Refusing is the only honest option: emptying the store while
// quietly skipping the arm would leave the observer's own bookkeeping wrong
// with nothing on screen to say so.
//
// The diagnostic names THIS cause specifically. The sibling refusal — an
// owned column, whose obligations discharge one at a time — has its own
// message, because a store hitting one of these should not be sent to read
// about the other.
import std/io
import std/store

std/store:new(t) { n: 0[i64] }

std/store:new(rows, capacity: 4) { v: i64 }
! removed _ |> std/store:stored { t.n: t.n - 1 }

std/store:insert(rows) { v: 1 }
    | row _ |> _
    | full |> _

std/store:clear(rows)
std/io:print.ln("n {{ t.n:d }}")
