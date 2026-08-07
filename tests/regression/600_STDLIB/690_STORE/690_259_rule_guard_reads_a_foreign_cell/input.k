// PINS: a rule arm's `when` guard reads a FOREIGN singleton's cell — the
// cross-store read lowers to the store object, not raw surface text. The
// guard is baked into host text inside create, before the whole-program
// walk runs, so the cell rewrite must happen at the bake site — the same
// read already lowered fine in insert seeds (690_192), body-if conditions
// (690_074) and fmt interpolations; the guard was the position that missed.
// Both polarities: the true guard fires its arm, the false one filters.

import std/io
import std/store

std/store:new(rows, capacity: 4) { id: i64 }
std/store:new(op) { code: 1[i64] }

std/store:insert(rows) { id: 7 }

std/store:rule(rows)
! row e when op.code == 1 |> std/io:print.ln("hit {{ e.id:d }}")

std/store:rule(rows)
! row e when op.code == 2 |> std/io:print.ln("miss {{ e.id:d }}")
