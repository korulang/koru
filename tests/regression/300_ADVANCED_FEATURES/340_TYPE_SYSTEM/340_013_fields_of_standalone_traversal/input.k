// PINS: `fields-of` as a STANDALONE traversal source — emergent iteration OUTSIDE a
// constructor. `std/types:fields-of(Player)` pulses `! each f` over Player's reflected
// fields (each `f` a comptime StructField, `.name` / `.type`), exactly the way ~for
// pulses `! each` over a range — iteration is emergent, not an iterator fed to a loop.
// Lowers to an `inline for` over `@typeInfo(Player).@"struct".fields` (fields are
// heterogeneous, so the loop must comptime-unroll). This is the same traversal the
// constructor's `! construct` half consumes (340_012); here it drives print directly.

import std/types
import std/io


std/types:struct(Player) {
    name: []const u8,
    health: i64,
}

std/types:fields-of(Player)
! each f |> std/io:print.ln("field: {{ f.name:s }}")
