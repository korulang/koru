// PINS: a sweep nested inside a sweep over the SAME store — the pairwise
// shape, N² including the self-pair.
//
// Each row accumulates every row's value, its own included, so all three
// rows land on the same total (1 + 2 + 3 = 6). Both bindings are read in one
// expression and the write addresses the outer row, so a cursor shared
// between the two sweeps cannot produce that total.
//
// The one-store twin of 690_110: there the two sweeps name different stores,
// here they name the same one, so the store name cannot stand in for the
// binding.
import std/io
import std/store

std/store:new(vals, capacity: 8) { v: i64, acc: i64 }

std/store:insert(vals) { v: 1, acc: 0 }
std/store:insert(vals) { v: 2, acc: 0 }
std/store:insert(vals) { v: 3, acc: 0 }

std/store:sweep(vals)
! sweep a |> std/store:sweep(vals)
    ! sweep b |> std/store:stored { a.acc: a.acc + b.v }

std/store:sweep(vals)
! sweep r |> std/io:print.ln("v {{ r.v:d }} acc {{ r.acc:d }}")
