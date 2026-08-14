// TEST: std/trellis — a kernel-CHAIN grammar, CONFORMING.
//
// Upgrades the permissive `std/kernel:init/kernel/.*` ok-arm into a law with
// one explicit kernel-chain invariant: a `std/kernel:step` opens a chain
// directly under the kernel scope and NEVER nests inside another step. A legal
// chain carries exactly one `step` op-token on its ancestry path; a nested
// step carries two, so `.*std/kernel:step/.*std/kernel:step` is the rejection
// arm, and it cannot false-positive on legitimate chains (which have one).
//
// The rest of the grammar is the placement rule (self/pairwise/step only under
// a std/kernel:init kernel scope). This program CONFORMS: a multistep chain,
// step wrapping pairwise then self. Expected: runs 2 steps, prints positions.

import std/trellis
import std/kernel
import std/io

std/trellis:define("kernel-chain")
| `.*std/kernel:step/.*std/kernel:step` _ => error "a std/kernel:step never nests inside another step — it opens a kernel chain directly under the kernel scope"
| `std/kernel:init/kernel/.*` _ => ok
| `.*std/kernel:self` _ => error "std/kernel:self outside a kernel chain (it must sit under std/kernel:init's kernel scope)"
| `.*std/kernel:pairwise` _ => error "std/kernel:pairwise outside a kernel chain (it must sit under std/kernel:init's kernel scope)"

std/trellis:enforce("kernel-chain")

std/kernel:shape(Pt) {
    x: f64,
    mass: f64,
}

std/kernel:init(Pt) {
    { x: 0.0, mass: 1.0 },
    { x: 1.0, mass: 2.0 },
}
| kernel k |> std/kernel:step(0..2)
    | step |> std/kernel:pairwise { k.mass += k.other.mass * 0.0 }
        |> std/kernel:self { k.x += 1.0 }
| computed c |> std/io:print.blk {
        x[0]={{ c[0].x:f }} x[1]={{ c[1].x:f }}
    }
