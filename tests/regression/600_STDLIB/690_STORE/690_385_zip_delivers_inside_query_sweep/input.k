// Positive pin: `std/control:zip` inside a `std/store:query` sweep arm —
// the producer's `! each` attaches and delivers `{first, second}` pairs
// per row visited, and the sweep's row borrow reads inside the pair
// arm. Pinned because the adjacent bind-across-boundary shape refuses
// (690_386): zip INSIDE the sweep is the working side of that wall.
import std/io
import std/store
import std/control

std/store:new(rows, capacity: 8) { v: i64 }
std/store:insert(rows) { v: 1 }
std/store:insert(rows) { v: 2 }

std/store:query(rows)
! query r |> std/control:zip(a: 0..2, b: 10..12)
    ! each { first, second } |> std/io:print.ln("{{ r.v:d }}:{{ first:d }}+{{ second:d }}")
