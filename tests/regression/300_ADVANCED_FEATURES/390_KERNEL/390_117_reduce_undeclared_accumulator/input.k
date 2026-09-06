// TEST: std/kernel — a reduce block that accumulates into a name with NO declared
// `<name>[<type>]` header is refused. The declared header is the ONLY way to
// introduce a reducer slot; a bare `+=` target is a compile error, not magic.
//
// `total[f64]` is declared; `weird` is used with NO declaration → refused with a
// located KORU123 that names the offending accumulator.

import std/kernel
import std/io

std/kernel:shape(Pt) {
    mass: f64,
}

std/kernel:init(Pt) {
    { mass: 1.0 },
    { mass: 2.0 },
}
| kernel k |> std/kernel:reduce {
    total[f64]
    weird += k.mass
}
| reduce r |> std/io:print.blk {
        total={{ r.total:f }}
    }
