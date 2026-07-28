// PINS: `std/store:insert`'s `| row` branch is OPTIONAL.
//
// The handle is real information — 690_018 addresses a row with it, 690_059
// takes through it — but the overwhelming majority of inserts do not want it,
// and a required branch made every one of them carry a line of pure ceremony:
//
//     std/store:insert(items) { v: 10 }
//     | row _ |> _
//
// A sparse consumer names only what it means; unhandled is a no-op. Same rule
// gallery's page-route already documents for its `| ?catalog` arms.
//
// `| full` deliberately stays REQUIRED: it hands a value BACK, and for an owned
// column that value still carries its obligation, so dropping it silently would
// leak (690_011 pins the full branch, 690_057/058 the drain).
//
// Both spellings stay legal — this is the seed of the insert, and taking the
// handle when you want it is not a tax on the case that does not.
import std/io
import std/store

std/store:new(items, capacity: 8) { v: i64 }

std/store:insert(items) { v: 10 }
std/store:insert(items) { v: 20 }
| row _ |> _

std/store:sweep(items)
! sweep { entity.v } |> std/io:print.ln("v {{ v:d }}")
