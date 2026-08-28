// TEST: std/kernel — `reduce` composes with `self` UNDER `step` in one init.
//
// Each step mutates every mass (self), then reduce aggregates the mutated state.
// This is the realistic shape a simulation needs: evolve the data AND answer a
// question about it in the same pass. Expected: self mass+=1.0 over 3 steps of
// masses [1,2] yields per-step sums [5,7,9] → total=21 count=6.
//
// 390_111 pins the self+reduce compose WITHOUT step; this one pins it under
// `step`, so the mutation the reduce reads is the post-self state each pass.

import std/kernel
import std/io

std/kernel:shape(Pt) {
    mass: f64,
}

std/kernel:init(Pt) {
    { mass: 1.0 },
    { mass: 2.0 },
}
| kernel k |> std/kernel:step(0..3)
    | step |> std/kernel:self { k.mass += 1.0 }
        |> std/kernel:reduce { total_mass += k.mass; count += 1 }
| reduce r |> std/io:print.blk {
        total={{ r.total_mass:f }} count={{ r.count:f }}
    }
