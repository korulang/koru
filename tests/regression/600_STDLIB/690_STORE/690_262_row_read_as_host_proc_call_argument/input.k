// PINS: a rule arm's row-binding column read (`e.id`), passed as a call
// argument to a HOST-BODIED proc, goes through the target's expression
// lowering in the parameter binding. The read arrives as the Zig column
// spelling; the JS inline-splice paths must lower it (`&` stripped, builtins
// mapped), never splice it raw — a raw splice is a SyntaxError at load.
// The same read into a Koru subflow callee and into a fmt interpolation was
// already correct; the opaque host-body splice was the position that missed.

import std/store

std/store:new(rows, capacity: 8) { id: i64 }

std/store:rule(rows)
! row e |> mk(): l |> show(e.id, label: l)

pub tor mk {} -> string
pub tor show { id: i64, label: string }

std/store:insert(rows) { id: 41 }
