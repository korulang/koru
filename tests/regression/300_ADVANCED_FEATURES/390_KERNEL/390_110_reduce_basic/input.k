// TEST: std/kernel — `reduce` accumulates named scalars out of the kernel scope via
// a dedicated `| reduce <name> |>` exit continuation. The accumulators are DECLARED
// in the reduce block as scoped slots (`<name>[<type>]`), which guides the codegen —
// the names, types, and zero-init are declared, never inferred from the body.
//
// `computed` binds the kernel ARRAY as a single-field identity (so `c[i]`
// resolves to element access); a reduced scalar has nowhere to live there, so
// it gets its own branch whose payload carries each declared accumulator as a
// named field. This kernel sums the element masses and counts the elements.
// Expected: run emits `total=6 count=3`.

import std/kernel
import std/io

std/kernel:shape(Pt) {
    x: f64,
    mass: f64,
}

std/kernel:init(Pt) {
    { x: 0.0, mass: 1.0 },
    { x: 1.0, mass: 2.0 },
    { x: 2.0, mass: 3.0 },
}
| kernel k |> std/kernel:reduce {
    total_mass[f64]
    count[i32]
    total_mass += k.mass
    count += 1
}
| reduce r |> std/io:print.blk {
        total={{ r.total_mass:f }} count={{ r.count:d }}
    }
