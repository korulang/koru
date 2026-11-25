// TEST: std/kernel — `scan` in literal (dataset) mode: declared
// loop-carried accumulator + ordered per-element writes, exited through
// `| computed |>` which carries the mutated array. Same grammar as
// `reduce`'s block — `name[type]` declarations, then `<name> <op>= <expr>`
// and `{k}.<field> <op>= <expr>` statements in source order.
// Expected: out = prefix sums of v = [1.0, -0.5, 2.0, 0.25]
// → out = [1.0, 0.5, 2.5, 2.75].

import std/kernel
import std/io

std/kernel:shape(Pt) {
    v: f64,
    out: f64,
}

std/kernel:init(Pt) {
    { v: 1.0, out: 0.0 },
    { v: -0.5, out: 0.0 },
    { v: 2.0, out: 0.0 },
    { v: 0.25, out: 0.0 },
}
| kernel k |> std/kernel:scan {
    run[f64]
    k.out = k.v + run
    run += k.v
}
| computed c |> std/io:print.blk {
        o0={{ c[0].out:f }} o1={{ c[1].out:f }} o2={{ c[2].out:f }} o3={{ c[3].out:f }}
    }
