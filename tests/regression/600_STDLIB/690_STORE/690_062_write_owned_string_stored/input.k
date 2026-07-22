// 690_062 — WRITE (stored-update) over an OWNED column: replace an owned String
// in place. The store DISCHARGES the evicted String (canonical discharger, free)
// and CONSUMES the incoming one's <!instance> (move in) — discharge-old +
// consume-new. Rust's `vec[i] = x` (drop the old, move the new), koru-explicit.
// After the rewrite, a query read shows "new"; the "old" String is freed at the
// write (no leak), and "new" is freed at teardown.
//
// MUST_RUN pin for the WRITE rung: the `stored` transform now generates the
// apply/write surface for owned columns (unit-4 unlocked past !has_owned), the
// write cell reads the OLD pointer, fires the discovered canonical discharger
// (free), then moves the NEW pointer in (its <!instance> consumed at the write
// call via the owned value slot's consume-phantom). Output "new" proves the
// in-place replace; no leak (old freed at write, new freed at teardown).
import std/io
import std/string
import std/store

std/store:new(names, capacity: 8) { label: *std/string:String<std/string:instance!> }

std/string:from-page(text: "old")
| ok s |> std/string:take(s): owned |> std/store:insert(names) { label: owned }
    | row r |> std/string:from-page(text: "new")
        | ok s2 |> std/string:take(s: s2): owned2 |> std/store:stored { names[r].label: owned2 }
        | err _ |> _
| err _ |> _

std/store:query(names)
! query { entity.label } |> std/string:read(s: label): text |> std/io:print.ln("{{ text:s }}")
