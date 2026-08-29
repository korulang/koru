// TEST: std/kernel — `reduce` composes with an array-mutating op in ONE init.
//
// `self` advances every element (side effect on the array), then `reduce`
// aggregates the final state through DECLARED accumulator slots (`<name>[<type>]`)
// in the reduce block. The kernel exits through the single `| reduce |>`
// continuation — the union-backed `computed` exit is not needed when the caller
// reads an aggregate rather than the array, so a step/self/pairwise + reduce
// kernel needs no second branch. Expected: self x+=1 turns x=[0,1] into [1,2],
// and reduce totals them → 3.

import std/kernel
import std/io

std/kernel:shape(Pt) {
    x: f64,
    mass: f64,
}

std/kernel:init(Pt) {
    { x: 0.0, mass: 1.0 },
    { x: 1.0, mass: 2.0 },
}
| kernel k |> std/kernel:self { k.x += 1.0 }
    |> std/kernel:reduce {
        total_x[f64]
        count[i32]
        total_x += k.x
        count += 1
    }
| reduce r |> std/io:print.blk {
        total={{ r.total_x:f }} count={{ r.count:d }}
    }
