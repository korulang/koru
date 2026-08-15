// TEST: std/kernel — step over a store: the in-process frame loop.
//
// 390_112 ran `self` once; 390_113 once across the parallel floor. This pins
// `std/kernel:step(0..N)` wrapping `self` over a store — the in-process
// frame loop the game usecase runs every frame, and the shape the scaling
// measurement needs (the kernel finally dominates the process).
//
// 65536 rows (crossing the parallel floor), 3 frames of vx += mass*0.1 then
// x += vx. Per row: frame1 vx=1.2 x=1.2; frame2 vx=1.4 x=2.6; frame3
// vx=1.6 x=4.2. The oracle is exact: rows == 65536, sum(x) == 65536*4.2,
// so a dropped frame or dropped chunk breaks the sums.

import std/io
import std/store
import std/kernel

std/store:new(world, capacity: 70000) { x: f64, vx: f64, mass: f64 }
std/store:new(cnt) { rows: 0[i64] }
std/store:new(acc) { xs: 0.0[f64], vs: 0.0[f64] }

for(0..65536)
! each i |> std/store:insert(world) { x: 0.0, vx: 1.0, mass: 2.0 }

std/kernel:init(world) {}
| kernel k |> std/kernel:step(0..3)
    | step |> std/kernel:self { k.vx += k.mass * 0.1; k.x += k.vx }

std/store:query(world)
! query r |> std/store:stored { cnt.rows: cnt.rows + 1 }
    |> std/store:stored { acc.xs: acc.xs + r.x, acc.vs: acc.vs + r.vx }

if(cnt.rows > 0)
| then |> std/io:print.ln("rows {{ cnt.rows:d }} xs {{ acc.xs:f }} vs {{ acc.vs:f }}")
| else |> _
