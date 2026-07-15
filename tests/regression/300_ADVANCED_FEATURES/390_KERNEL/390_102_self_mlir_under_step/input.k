// Test 390_102: self|mlir under kernel:step — in-place ABI makes re-invocation sound.
//
// Companion to 390_101 (chained ops compose). Under the buffer/memref ABI the
// generated kernel mutates the host buffer in place, so kernel:step calling it
// once per iteration accumulates state exactly like the Zig-loop sibling in
// 390_070. (The 1a internalize-init ABI would have recomputed from t0 every
// step; a wall rejected the combination until this slice.)
//
// step(0..3) wrapping self|mlir { k.mass += 0.2 }: three iterations of +0.2
// → 1.6, 2.6, 3.6 — same numbers as 390_070_step_basic.

import std/kernel
import std/io

std/kernel:shape(Body) {
    mass: f64,
}

std/kernel:init(Body) {
    { mass: 1.0 },
    { mass: 2.0 },
    { mass: 3.0 },
}
| kernel k |> std/kernel:step(0..3)
    | step |> std/kernel:self|mlir { k.mass += 0.2 }
| computed c |> std/io:print.blk {
        mass[0]={{ c[0].mass:f }} mass[1]={{ c[1].mass:f }} mass[2]={{ c[2].mass:f }}
    }
