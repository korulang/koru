// PINS: the retired projection block is REFUSED, and the diagnostic teaches the
// binding that replaced it. Rule 7 of the ruleset 690_086 heads — `entity` stops
// existing — held as a wall rather than as prose, because the old form is not
// merely worse: `{ entity.v }` bound `v` into the body's scope, so a program
// left un-migrated would keep compiling and silently mean something else.
import std/io
import std/store

std/store:new(items, capacity: 4) { v: i64 }
std/store:insert(items) { v: 10 }

std/store:query(items)
! query { entity.v } |> std/io:print.ln("v {{ v:d }}")
