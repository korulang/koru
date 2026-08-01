// 690_064 — MIXED-FIELD WRITE: write a NON-owned (scalar) field of a store
// that ALSO has an owned column. The todo-app blocker: a
// `{ label: *String<instance!>, done: i64 }` store must let you toggle `done`
// without touching `label`.
//
// The wall (690_062's sibling, store.kz ~3936): the plural write surface
// bundles ALL columns into one __store_write_(row, field, value_0, value_1)
// event, unwritten slots riding as "typed zeros no arm reads". A scalar's zero
// is cheap; an OWNED slot carries a consume-phantom <!instance> and has NO zero
// (nothing to consume), so a `done`-only write was rejected — it would demand
// an owned value for the untouched `label` slot.
//
// The fix DE-BUNDLES the write for owned-containing stores (captured-style
// targeted field assignment): writing `done` threads only value_done, never
// referencing the owned `label` slot or its obligation. The apply arm for
// `done` already writes only its own cell and dispatches only its own field's
// taps — the bundling was signature-only. The owned `label` is left intact
// (its <instance!> still lives, freed at teardown).
//
// Proves: `done` 0->1 in a mixed owned+scalar store; the owned `label` survives
// the scalar write untouched. Output "task done=1".
import std/io
import std/string
import std/store

std/store:new(todos, capacity: 8) { label: *std/string:String<std/string:instance!>, done: i64 }

std/string:from-page(text: "task")
| ok s |> std/string:take(s): owned |> std/store:insert(todos) { label: owned, done: 0 }
    | row r |> std/store:stored { todos[r].done: 1 }
| err _ |> _

std/store:sweep(todos)
! sweep e |> std/string:read(s: e.label): text |> std/io:print.ln("{{ text:s }} done={{ e.done:d }}")
