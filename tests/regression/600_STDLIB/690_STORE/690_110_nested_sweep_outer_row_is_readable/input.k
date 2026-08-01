// PINS: the OUTER row binding is readable from inside a nested sweep's body.
//
// Two rows per store, so a shared row cursor cannot hide behind index 0 ==
// index 0. Each outer row must pair with every inner row, and `o.v` must
// name the outer store's column at the outer cursor.
//
// 690_086 pins that a sweep arm binds its row; 690_087 pins that two nested
// sweeps resolve independently, with a body that touches only the inner
// binding. This pin is the cross-row read those two leave uncovered: the
// outer binding named from inside the inner body.
import std/io
import std/store

std/store:new(outer, capacity: 4) { v: i64 }
std/store:new(inner, capacity: 4) { v: i64 }

std/store:insert(outer) { v: 10 }
std/store:insert(outer) { v: 20 }
std/store:insert(inner) { v: 1 }
std/store:insert(inner) { v: 2 }

std/store:query(outer)
! query o |> std/store:query(inner)
    ! query i |> std/io:print.ln("o {{ o.v:d }} i {{ i.v:d }}")
