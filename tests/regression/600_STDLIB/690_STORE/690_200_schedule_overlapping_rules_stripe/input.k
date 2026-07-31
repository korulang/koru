// PINS: ecs_bench_suite's `schedule` as STANDING rules — 690_123's sibling.
// There the three systems are root-position sweeps composing by program
// position; here they are [name]d rules whose read/write sets OVERLAP on vx
// (integrate writes it, advance reads it, damp writes it again), serialized
// by declared [depends_on] edges — the author-declared analogue of what
// their scheduler derives from read/write sets. Each rule fires twice: once
// at its root position (textual order), once under the stripe (topo order);
// with the edges matching textual order that is two frames of the schedule.
// Frame 1, row 1: vx 1+2=3, px 0+3=3, vx 6. Frame 2: vx 8, px 11, vx 16.
import std/io
import std/store

std/store:new(world, capacity: 8) { px: i64, vx: i64, ax: i64 }

std/store:insert(world) { px: 0, vx: 1, ax: 2 }
| row _ |> _
| full |> _

std/store:insert(world) { px: 100, vx: 10, ax: 1 }
| row _ |> _
| full |> _

[name(integrate)]std/store:query(world)
! query s1 |> std/store:stored { s1.vx: s1.vx + s1.ax }

[name(advance)|depends_on(integrate)]std/store:query(world)
! query s2 |> std/store:stored { s2.px: s2.px + s2.vx }

[name(damp)|depends_on(advance)]std/store:query(world)
! query s3 |> std/store:stored { s3.vx: s3.vx * 2 }

std/store:stripe(world)

std/store:sweep(world)
! sweep r |> std/io:print.ln("p {{ r.px:d }} v {{ r.vx:d }}")
