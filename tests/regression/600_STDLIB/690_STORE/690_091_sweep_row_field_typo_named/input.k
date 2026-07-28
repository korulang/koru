// PINS: `<row>.<not-a-field>` is named by the store, not passed to the host.
//
// The binding makes this decidable in a way the projection block did not: once
// `e` is known to BE the row, `e.w` cannot be anything but a field of `items`,
// so a miss is a typo the store can spell out. Left unclaimed it reaches the
// backend as `undeclared identifier '__koru_srf_w'` or worse, an accidental
// match against an enclosing name.
import std/io
import std/store

std/store:new(items, capacity: 4) { v: i64 }
std/store:insert(items) { v: 10 }

std/store:sweep(items)
! sweep e |> std/io:print.ln("w {{ e.w:d }}")
