// PINS: a two-column SWAP in one sweep arm, no temporary column — the chain
// binds the old value, the `stored` block spends it.
//
// Written-order lands a plural block's entries in sequence (690_126), so
// `{ e.a: e.b, e.b: e.a }` is a duplicate, not a swap. The ruling: a swap does
// not belong in `stored` at all — `stored` is a write block, and upstream work
// is the chain. `echo(v: e.a): t` holds `a`'s old value; then `e.a` is
// overwritten first and `e.b` takes the bind. Written-order is the mechanism.
//
// Two rows, values derived per row, so the pin also covers the bind REBINDING
// each iteration rather than freezing on row zero.
//
// The alternative — staging the old value through a store column — is ruled
// out: sweep cost is linear in columns touched (measured 1.00 : 1.93 : 3.20
// for 2 : 4 : 6 columns), and a silent perf tax is against the tenet. This
// composition is the temp-free spelling that makes that ruling livable.
import std/io
import std/store

tor echo { v: i64 } -> i64
echo -> v

std/store:new(cells, capacity: 4) { a: i64, b: i64 }

std/store:insert(cells) { a: 3, b: 7 }
std/store:insert(cells) { a: 10, b: 20 }

std/store:query(cells)
! query e |> echo(v: e.a): t |> std/store:stored { e.a: e.b, e.b: t }

std/store:query(cells)
! query r |> std/io:print.ln("a {{ r.a:d }} b {{ r.b:d }}")
