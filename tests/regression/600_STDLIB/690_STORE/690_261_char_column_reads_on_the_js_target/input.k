// PINS: a fixed-char column has a JavaScript lowering — the char cell on the
// JS target IS a string (seeded "", truncated at insert), so a rule-body read
// is the plain column read. The Zig spelling (`@import("std").mem.sliceTo`)
// must never reach the JS emitter: `@import` has no entry in its builtin
// table and the whole build aborts. 690_052 is this shape on the Zig lane;
// cross-target here, one row, read back through the rule's fmt interpolation.

import std/io
import std/store

std/store:new(rows, capacity: 16) { id: i64, label: char[32] }

std/store:insert(rows) { id: 1, label: "hello" }

std/store:rule(rows)
! row e |> std/io:print.ln("row {{ e.id:d }} {{ e.label:s }}")
