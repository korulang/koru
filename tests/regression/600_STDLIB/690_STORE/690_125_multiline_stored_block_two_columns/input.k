// PINS: 690_118's plural stored block with its ONLY change being LINE BREAKS
// — the two-column write laid out one field per line, the way a consumer
// formats an integration step once it has three fields.
//
// A separate pin because a spelling variant is a separate ask (concept:
// frag-a-corpus-exercises-its-authors-idioms): the single-line and multi-line
// forms can diverge — a fix that lands for the one the corpus happens to
// write leaves the other unexercised, and this block sits mid-arm where a
// multi-line chain has swallowed following arms before. Same covered shape as
// 690_118: both writes land, the row binding survives the second field.
import std/io
import std/store

std/store:new(ents, capacity: 4) { px: i64, vx: i64, py: i64, vy: i64 }

std/store:insert(ents) { px: 0, vx: 1, py: 0, vy: 2 }
std/store:insert(ents) { px: 10, vx: 3, py: 20, vy: 4 }

std/store:query(ents)
! query e |> std/store:stored {
    e.px: e.px + e.vx,
    e.py: e.py + e.vy
}

std/store:query(ents)
! query r |> std/io:print.ln("p {{ r.px:d }} {{ r.py:d }}")
