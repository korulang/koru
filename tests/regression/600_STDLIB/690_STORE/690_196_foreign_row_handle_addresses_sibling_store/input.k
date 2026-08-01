// PINS: a row handle minted by ONE store must not address a DIFFERENT store.
//
// `__koru_resolve` already carries the refusal for this case verbatim —
// "the value is not a handle this store issued (handles come from `| row` and
// row cursors)" — so the guarantee is claimed. It cannot fire: the resolve
// checks slot bounds and generation only, and two stores filled in the same
// order mint identical slot|gen values, so a sibling's handle passes both.
//
// This is the 690_115/116 trap floor's missing direction. Those pin a handle
// that has gone STALE against its own store; this pins a handle that was
// never this store's to begin with. Same guard, same message, the mirror
// nobody wrote.
import std/io
import std/store

std/store:new(src, capacity: 4) { v: i64 }
std/store:new(dst, capacity: 4) { v: i64 }

std/store:insert(dst) { v: 100 }
| row _ |> _
| full |> _

std/store:insert(src) { v: 1 }
| row r |> std/store:stored { dst[r].v: 999 }
| full |> _

std/store:query(dst)
! query b |> std/io:print.ln("dst {{ b.v:d }}")
