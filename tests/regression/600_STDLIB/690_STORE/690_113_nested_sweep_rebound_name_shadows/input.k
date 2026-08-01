// PINS: rule 4 of 690_086 for ROW bindings — a nested sweep arm that rebinds
// the outer arm's name shadows it, innermost first. Under the inner arm,
// `k.v` is the INNER store's row; the outer row is unreachable there by
// rule, not by pass order.
//
// Two rows in the outer store, so the inner values printing once per outer
// row is what distinguishes shadowing from the outer binding claiming the
// reads: the outer values (10, 20) must never appear.
import std/io
import std/store

std/store:new(outer, capacity: 4) { v: i64 }
std/store:new(inner, capacity: 4) { v: i64 }

std/store:insert(outer) { v: 10 }
std/store:insert(outer) { v: 20 }
std/store:insert(inner) { v: 1 }
std/store:insert(inner) { v: 2 }

std/store:query(outer)
! query k |> std/store:query(inner)
    ! query k |> std/io:print.ln("k {{ k.v:d }}")
