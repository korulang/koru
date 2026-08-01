// PINS: nested sweeps resolve independently — a read and a write in the same
// arm mean the SAME row. Head pin: 690_086 carries the ruleset.
//
// This is the defect that exposed `entity`, measured 2026-07-28 on the shape
// below before any redesign:
//
//     read  entity.v  -> INNER store   (100)
//     write entity.v  -> OUTER store   (777, inner untouched)
//
// Same arm. Silently. The cause is not a scoping rule that picked wrong — there
// was no scope at all. The rewrite matched the literal token `entity` across a
// subtree, and with two sweeps nested BOTH rewrites matched it; the outer runs
// first and wins.
//
// Binding the row fixes this with no scoping rule written: `o` and `i` are two
// distinct tokens, so there is nothing to resolve and nothing to shadow. That
// is the argument for the whole redesign, stated as a program.
//
// The write below names the INNER row, so `inner` moves and `outer` does not.
import std/io
import std/store

std/store:new(outer, capacity: 4) { v: i64 }
std/store:new(inner, capacity: 4) { v: i64 }

std/store:insert(outer) { v: 1 }
std/store:insert(inner) { v: 100 }

std/store:query(outer)
! query o |> std/store:query(inner)
    ! query i |> std/store:stored { i.v: 777 }

std/store:query(outer)
! query o |> std/io:print.ln("outer {{ o.v:d }}")

std/store:query(inner)
! query i |> std/io:print.ln("inner {{ i.v:d }}")
