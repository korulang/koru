// PINS: a sweep arm can reach the 0-based ROW ORDINAL — the layout cursor a
// retained renderer needs. `! draw |> sweep(store) ! sweep <row> |>
// write-at(y: <ordinal>, …)` is the render-bridge shape: what a row's fields
// say is independent of WHERE it sits on screen, and only the sweep knows the
// second thing.
//
// THE ORDINAL HAS NO SPELLING. 690_086's ruleset binds the row and routes every
// reference through `<row>.<field>`, and an ordinal is not a field — it is a
// property of the visit, not of the row. The seven rules ruled 2026-07-28 do
// not mention it, and neither DESIGN.md nor the membrane rules it anywhere
// else. So this test keeps the RETIRED projection form below: it is the last
// spelling that expressed the requirement, held here so the requirement does
// not quietly leave the corpus with the syntax that carried it.
//
// The sibling constructs do not answer it either — `for` binds `! each i` with
// no index, so nothing in the language currently hands a loop its counter.
// Lars rules the spelling; this pin is the evidence, not a proposal.
import std/io
import std/store
std/store:new(items, capacity: 8) { v: i64 }
std/store:insert(items) { v: 10 }
std/store:insert(items) { v: 20 }
std/store:insert(items) { v: 30 }
for(0..1)
! each _ |> std/store:sweep(items)
    ! sweep { entity.v, row } |> std/io:print.ln("row {{ row:d }} = {{ v:d }}")
