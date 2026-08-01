// PINS: rule 4 of the ruleset 690_086 heads — "resolution order: bindings
// (innermost first) -> module-local stores -> `[global(name)]` stores." A row
// binding is an inner scope and must cover a store's name like any other.
//
// `items` is both the store being swept and the arm's row binding, so `items.v`
// inside the arm is THE ROW. Rule 5 says the same thing from the other side:
// "shadowing is allowed... a store is not a special case."
//
// MEASURED CAUSE (2026-07-28): the store wins, and it wins on PASS ORDER, not
// on a resolution rule. `new`'s create-time whole-program Walk rewrites
// `<store>.<field>` everywhere it appears before sweep's site transform runs,
// so `items.v` has already become the SoA cell by the time the arm's binding
// exists. The backend then reports `invalid format string 'd' for type
// '[4]i64'` — the whole column array, where the row's own `i64` belongs.
//
// This is the same shape as the `entity` defect the binding replaced: a textual
// rewrite with no scope, applied at a moment when the scope it needs is not
// built yet. Binding the row fixed the case where the rewrite matched a magic
// word; it does not by itself fix the case where the rewrite matches a store's
// real name. Membrane note: std/store SITES skip create's Walk for their own
// args (transforms own the rewriting) — but a `print.ln` in a sweep body is not
// a std/store site, so the Walk reaches it.
import std/io
import std/store

std/store:new(items, capacity: 4) { v: i64 }
std/store:insert(items) { v: 10 }
std/store:insert(items) { v: 20 }

std/store:query(items)
! query items |> std/io:print.ln("v {{ items.v:d }}")
