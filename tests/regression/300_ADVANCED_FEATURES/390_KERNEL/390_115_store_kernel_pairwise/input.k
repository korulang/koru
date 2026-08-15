// TEST: std/kernel — pairwise over a store: k.other resolves to the partner
// row's columns (SoA), symmetric writes, N²/2 over the store's live length.
//
// Two bodies, one frame: pairwise force (dx = x0 - x1, mag 0.1) then self
// integration. b0: v 1 + (-1)(3)(0.1) = 0.7, x 0+0.7 = 0.7. b1: v 2 +
// (-1)(2)(0.1) = 1.8, x 1+1.8 = 2.8. Serial by design this rung — pairwise
// writes BOTH endpoints per pair (not disjoint), so the parallel `self`
// machinery stays off until the deterministic-reduction contract lands.

import std/io
import std/store
import std/kernel

std/store:new(world, capacity: 8) { x: f64, vx: f64, mass: f64 }

std/store:insert(world) { x: 0.0, vx: 1.0, mass: 2.0 }
std/store:insert(world) { x: 1.0, vx: 2.0, mass: 3.0 }

std/kernel:init(world) {}
| kernel k |> std/kernel:step(0..1)
    | step |> std/kernel:pairwise {
            const dx = k.x - k.other.x;
            const mag = 0.1;
            k.vx += dx * k.other.mass * mag;
            k.other.vx += dx * k.mass * mag;
        } |> std/kernel:self {
                k.x += k.vx;
            }

std/store:query(world)
! query r |> std/io:print.ln("x {{ r.x:f }} v {{ r.vx:f }}")
