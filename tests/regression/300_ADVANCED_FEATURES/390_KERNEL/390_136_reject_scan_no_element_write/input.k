// TEST: std/kernel — `scan` with no `{k}.<field>` write is refused (KORU123):
// a scan's output IS the mutated elements, so accumulator-only state is
// dead compute trapped in the kernel scope with no exit. Same doctrine as
// the computed-less kernel refusal.

import std/kernel
import std/io

std/kernel:shape(Pt) {
    mass: f64,
}

std/kernel:init(Pt) {
    { mass: 1.0 },
    { mass: 2.0 },
}
| kernel k |> std/kernel:scan {
    run[f64]
    run += k.mass
}
| computed c |> std/io:print.ln("unreachable")
