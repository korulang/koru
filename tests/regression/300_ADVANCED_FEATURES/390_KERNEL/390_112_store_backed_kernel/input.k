// TEST: std/kernel — a store-backed kernel. `std/kernel:init(world)` with an
// empty dataset names a std/store:new store: the kernel iterates the store's
// SoA columns in place (raw column access, no watch/apply dispatch — the
// store is the observable, so no | computed |> exit is required), bounded by
// the store's LIVE length. Expected: self applies vx += mass*0.1 then
// x += vx to each row; the query afterwards sees the mutations.

import std/io
import std/store
import std/kernel

std/store:new(world, capacity: 32) { x: f64, vx: f64, mass: f64 }

std/store:insert(world) { x: 0.0, vx: 1.0, mass: 2.0 }
std/store:insert(world) { x: 10.0, vx: -1.0, mass: 3.0 }
std/store:insert(world) { x: 100.0, vx: 0.5, mass: 4.0 }

std/kernel:init(world) {}
| kernel k |> std/kernel:self { k.vx += k.mass * 0.1; k.x += k.vx }

std/store:query(world)
! query r |> std/io:print.ln("x {{ r.x:f }} v {{ r.vx:f }}")
