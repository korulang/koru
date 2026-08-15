// PIN: a store-loop-insert DIRECTLY FOLLOWED by a store-backed kernel
// declaration triggers KORU010 "stray continuation line without Koru
// construct" at the kernel's `| kernel k |>` continuation — measured
// 2026-08-15 while building the large-N pairwise probe. The same loop
// WITHOUT a following kernel compiles (690_194); the same kernel after
// plain `std/store:insert` lines compiles (390_112...); the combination
// `for(0..N) ! each i |> insert(...)` then `std/kernel:init(world) {}`
// breaks the parser's continuation attachment. A game world with thousands
// of rows built by loops cannot sit in front of a kernel today.
import std/io
import std/store
import std/kernel

std/store:new(world, capacity: 64) { x: f64, vx: f64, mass: f64 }

for(0..3)
! each i |> std/store:insert(world) { x: 0.0, vx: 1.0, mass: 2.0 }

std/kernel:init(world) {}
| kernel k |> std/kernel:self { k.x += k.vx }
