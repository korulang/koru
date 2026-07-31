// PINS: a plural stored block's entries land IN WRITTEN ORDER — a later rhs
// reads the value an earlier entry in the SAME block already wrote, not the
// pre-sweep value. `{ e.a: e.b, e.b: e.a }` is a duplicate, not a swap.
//
// 690_118 pins that both writes land; which value the second rhs SEES was
// never asked. The answer is load-bearing surface, not trivia: 690_128 factors
// a determinant into a column and reuses it from sixteen later entries of the
// same block — that spelling is correct only under this order. An in-place
// transform (every output reading every input, 690_127's inverse) is the
// mirror cost: it cannot be one block and must stage through output columns.
//
// If simultaneous-read semantics is ever ruled instead, this flips together
// with 690_128 by that ruling and a migration, not by nobody noticing.
import std/io
import std/store

std/store:new(cells, capacity: 2) { a: f64, b: f64 }

std/store:insert(cells) { a: 3.0, b: 7.0 }

std/store:sweep(cells)
! sweep e |> std/store:stored { e.a: e.b, e.b: e.a }

std/store:sweep(cells)
! sweep r |> std/io:print.ln("a {{ r.a:f }} b {{ r.b:f }}")
