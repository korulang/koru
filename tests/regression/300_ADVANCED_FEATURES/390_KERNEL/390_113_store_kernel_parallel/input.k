// TEST: std/kernel — a store-backed self kernel AUTO-PARALLELIZES at scale.
//
// The store-backed `self` op (390_112) writes DISJOINT rows, so the kernel
// transform may split the row range across threads with the result BIT-
// IDENTICAL to the serial loop at any split — no FP reassociation, no oracle
// change. The emission is adaptive per call: below a row-count floor (or
// single-cpu) it runs the serial loop; above it, up to cpu-count threads,
// spawn failure or an empty tail falling back inline so no row is skipped.
//
// This pins the parallel path: 65536 rows (>= floor), every row identical
// work (vx += mass*0.1, x += vx), then the whole store is summed. The oracle
// is exact: rows == 65536 and each row ends at x == vx == 1.2, so a dropped
// or double-processed chunk would break the sums by 1.2 or a multiple of it.

import std/io
import std/store
import std/kernel

std/store:new(world, capacity: 70000) { x: f64, vx: f64, mass: f64 }
std/store:new(cnt) { rows: 0[i64] }
std/store:new(acc) { xs: 0.0[f64], vs: 0.0[f64] }

for(0..65536)
! each i |> std/store:insert(world) { x: 0.0, vx: 1.0, mass: 2.0 }

std/kernel:init(world) {}
| kernel k |> std/kernel:self { k.vx += k.mass * 0.1; k.x += k.vx }

std/store:query(world)
! query r |> std/store:stored { cnt.rows: cnt.rows + 1 }
    |> std/store:stored { acc.xs: acc.xs + r.x, acc.vs: acc.vs + r.vx }

if(cnt.rows > 0)
| then |> std/io:print.ln("rows {{ cnt.rows:d }} xs {{ acc.xs:f }} vs {{ acc.vs:f }}")
| else |> _
