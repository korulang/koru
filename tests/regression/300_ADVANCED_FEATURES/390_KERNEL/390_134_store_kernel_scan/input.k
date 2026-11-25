// TEST: std/kernel — `scan` prefix-sums a store's SoA columns in place.
// `name[type]` entries declare loop-carried accumulators; the remaining
// entries are per-element statements run IN ORDER, with `k.<field>` bound
// to the store column at [i]. Strictly serial — a prefix recurrence is
// not row-disjoint, so the store parallel path never applies.
// Expected: out[i] = sum(v[0..=i]) for v = [1.0, -0.5, 2.0, 0.25]
// → out = [1.0, 0.5, 2.5, 2.75].

import std/io
import std/store
import std/kernel

std/store:new(world, capacity: 8) { v: f64, out: f64 }

std/store:insert(world) { v: 1.0, out: 0.0 }
std/store:insert(world) { v: -0.5, out: 0.0 }
std/store:insert(world) { v: 2.0, out: 0.0 }
std/store:insert(world) { v: 0.25, out: 0.0 }

std/kernel:init(world) {}
| kernel k |> std/kernel:scan {
    run[f64]
    k.out = k.v + run
    run += k.v
}

std/store:query(world)
! query r |> std/io:print.ln("v={{ r.v:f }} out={{ r.out:f }}")
