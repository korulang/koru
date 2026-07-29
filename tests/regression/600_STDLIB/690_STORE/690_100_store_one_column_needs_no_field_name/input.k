// A store with ONE column names no field — the store's own name is the name.
//
// Koru forbids a single-field record by construction, and spells the one-thing
// case bare everywhere else:
//
//     | branch { illegal: i64 }        <- a single-field record, refused
//     | legal-branch i64               <- the identity form
//
// A store declaring `{ v: i64 }` writes exactly the shape the language refuses,
// and then every hand-back lowers it away again — `| item`, `| full` and
// `! discharge` each carry an arity special-case for it. Declared bare there is
// no field to reach past and nothing to lower.
//
// The row block is the VALUE, never a field list, which is what settles punning
// here: `insert(nums) { 7 }` cannot be read as a pun because there is no column
// name to pun against. One reading, decided by the store's arity.
//
// `capture { entity }` already spells a one-slot block bare (control.kz) — the
// store was the outlier.
import std/io
import std/store

std/store:new(nums, capacity: 4) { i64 }

std/store:insert(nums) { 7 }
| row _ |> _
std/store:insert(nums) { 9 }
| row _ |> _

std/store:sweep(nums)
! sweep n |> std/io:print.ln("n {{ n:d }}")
