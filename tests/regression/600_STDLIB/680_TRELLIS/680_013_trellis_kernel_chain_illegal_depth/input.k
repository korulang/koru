// TEST: std/trellis — a kernel-CHAIN law rejects a step nested inside a step.
//
// The NEGATIVE half of 680_012. A legal chain carries exactly one `step`
// op-token on its ancestry path; this program's second `std/kernel:step` sits
// in the outer step's step-branch, so its path carries two:
//
//   std/kernel:init/kernel/std/kernel:step/step/std/kernel:step
//
// The `.*std/kernel:step/.*std/kernel:step` arm fires. The trellis halts the
// compile at the legality boundary (Stage C, before the kernel transforms
// touch the tree), so the user gets a located trellis message — not a
// transform panic or generated-Zig wreckage from the malformed multistep.

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

// VIOLATION: a `std/kernel:step` nesting inside a `std/kernel:step`'s
// step-branch — a second step op-token on the path.
std/kernel:init(Pt) {
    { x: 0.0, mass: 1.0 },
}
| kernel k |> std/kernel:step(0..2)
    | step |> std/kernel:step(0..2)
        | step |> std/kernel:self { k.x += 1.0 }
