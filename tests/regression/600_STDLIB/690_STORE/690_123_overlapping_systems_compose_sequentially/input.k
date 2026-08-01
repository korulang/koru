// PINS: three systems as three back-to-back sweeps over one store, their
// read/write sets OVERLAPPING on a column — s1 writes vx, s2 reads it into
// px, s3 writes vx again — and each later system observes the earlier one's
// writes. row1: vx 1+2=3, px 0+3=3, vx 3*2=6.
//
// This is ecs_bench_suite's schedule (rust-gamedev's workload), minus the
// scheduler: their point is running non-overlapping systems in parallel and
// serializing the overlapping pair. Koru has no surface for outer parallelism
// — no spelling exists to even ask (T7/O7's rung) — so the sequential
// composition IS the whole current semantics, and this pin is the baseline a
// disjointness-proving scheduler must preserve on the overlapping pair.
import std/io
import std/store

std/store:new(world, capacity: 8) { px: i64, vx: i64, ax: i64 }

std/store:insert(world) { px: 0, vx: 1, ax: 2 }
std/store:insert(world) { px: 100, vx: 10, ax: 1 }

std/store:query(world)
! query s1 |> std/store:stored { s1.vx: s1.vx + s1.ax }

std/store:query(world)
! query s2 |> std/store:stored { s2.px: s2.px + s2.vx }

std/store:query(world)
! query s3 |> std/store:stored { s3.vx: s3.vx * 2 }

std/store:query(world)
! query r |> std/io:print.ln("p {{ r.px:d }} v {{ r.vx:d }}")
