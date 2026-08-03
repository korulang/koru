// Koru entry for the ECS surface benchmark.
//
// Same CLI contract as the Zig baseline and the Bevy entry: one JSON line on
// stdout per run, `sink` as the anti-DCE checksum.
//
//     --scenario <name> --entities N --frames N --observers N
//
// Everything here is pure Koru — the flag parser, the world, the systems and
// the emitter. There is no `~proc|zig` in this file; the only host code
// reached is the standard library.
//
// A scenario that has not been ported refuses on stderr and emits no line, so
// an absent row in results.jsonl means "not implemented", never "ran and
// produced nothing".
//
// Two deviations from the Zig baseline, both structural rather than
// convenient:
//
//   - Store capacity is a compile-time literal, so the world is SIZED for the
//     harness's 100_000 entities instead of allocated per run. `--entities`
//     above that is refused by insert's `full` arm, not truncated.
//   - The checksum is read back OUTSIDE the timed region. A cell names a row
//     by handle, never by position, so the baseline's "first 16 elements" is
//     not spellable; a whole-store sum is the stronger oracle anyway.
//     `std/time:now` is opaque enough that the read cannot be hoisted over it.
import std/io
import std/store
import std/args
import std/string
import std/regex
import std/time
import std/grid

// The world. Striped, so a column a scenario never touches costs its sweeps
// nothing — `dense` reads px/py/vx/vy and never pays for hp or act.
std/store:new(bodies, capacity: 100000) { px: f32, py: f32, vx: f32, vy: f32, hp: i64, act: i64 }

// `add_remove` toggles a flag over its own array, exactly as the baseline
// does — it never builds a world.
std/store:new(marks, capacity: 100000) { on: i64 }

// `bevy_strength_world` splits its population three ways — half dynamic
// bodies, a quarter particles, a quarter orbiters — so it gets three stores.
// This is the scenario the harness's README says is "intended to favor Bevy
// ECS": packed archetypes, modular systems, math-heavy iteration.
std/store:new(dyn, capacity: 50000) { px: f32, py: f32, vx: f32, vy: f32, ax: f32, ay: f32 }
std/store:new(parts, capacity: 25000) { px: f32, py: f32, vx: f32, vy: f32, life: i64, alive: i64 }
std/store:new(orbs, capacity: 25000) { px: f32, py: f32, phase: f32, radius: f32, speed: f32 }

// `boids` is the DOTS port, and it is the first scenario here that needs a
// SPATIAL INDEX. The README's `combat_world` entry says a spatial index is the
// first thing a borrowed ECS workload asked for that std/store has no answer
// to — this is that answer: a static, positionally-addressed grid beside the
// store, not a collection the world holds.
//
// 32x32x32 cells over a 256-unit cube at DOTS' own CellRadius of 8. The grid is
// a flat run and the program linearises `(z*32 + y)*32 + x` itself, which is
// what `size:` rather than `dimensions:` is for: a spatial hash's index is the
// program's own business.
std/grid:new(cells, size: 32768) { count: 0[i64], ax: 0.0[f32], ay: 0.0[f32], az: 0.0[f32], sx: 0.0[f32], sy: 0.0[f32], sz: 0.0[f32], ti: 0[i64], od: 0.0[f32] }

// `tf*` and `nh*` are the steering accumulators. The store has no
// expression-local binding, so an intermediate that Zig and Rust hold in a
// register lives in a column here and the stages chain through it. The
// arithmetic is identical, so the checksum still has to match bit-for-bit.
std/store:new(flock, capacity: 100000) { px: f32, py: f32, pz: f32, fx: f32, fy: f32, fz: f32, cell: 0[i64], tfx: 0.0[f32], tfy: 0.0[f32], tfz: 0.0[f32], nhx: 0.0[f32], nhy: 0.0[f32], nhz: 0.0[f32] }

// The two target fish and the one shark, moved on a sawtooth. DOTS key-frames
// them; a benchmark needs them deterministic, and a sawtooth avoids libm
// trigonometry, which differs in the last ulp between toolchains and would
// break the cross-arm checksum before the algorithm got a chance to.
// Two singletons, not one: a singleton store's columns must all share one
// scalar type (a plural store may mix them, as `bodies` does), so the frame
// counter cannot sit beside the f32 actor positions.
std/store:new(fr) { t0x: 0.0[f32], t0y: 0.0[f32], t0z: 0.0[f32], t1x: 0.0[f32], t1y: 0.0[f32], t1z: 0.0[f32], obx: 0.0[f32], oby: 0.0[f32], obz: 0.0[f32] }
std/store:new(frn) { n: 0[i64] }


std/store:new(cfg) { which: 0[i64], scenario: 0[i64], entities: 100000[i64], frames: 100[i64], observers: 25[i64] }
std/store:new(acc) { sink: 0[i64] }

// ---------------------------------------------------------------- flag parse

tor store-num { v: i64 }
store-num = if(cfg.which == 2)
| then |> std/store:stored { cfg.entities: v, cfg.which: 0 }
| else |> if(cfg.which == 3)
    | then |> std/store:stored { cfg.frames: v, cfg.which: 0 }
    | else |> if(cfg.which == 4)
        | then |> std/store:stored { cfg.observers: v, cfg.which: 0 }
        | else |> std/store:stored { cfg.which: 0 }

tor set-scenario { a: string }
set-scenario = std/regex:match(a)
| `dense` _ |> std/store:stored { cfg.scenario: 1, cfg.which: 0 }
| `sparse` _ |> std/store:stored { cfg.scenario: 2, cfg.which: 0 }
| `query_get` _ |> std/store:stored { cfg.scenario: 3, cfg.which: 0 }
| `schedule_empty` _ |> std/store:stored { cfg.scenario: 4, cfg.which: 0 }
| `spawn` _ |> std/store:stored { cfg.scenario: 5, cfg.which: 0 }
| `spawn_batch` _ |> std/store:stored { cfg.scenario: 6, cfg.which: 0 }
| `despawn` _ |> std/store:stored { cfg.scenario: 7, cfg.which: 0 }
| `add_remove` _ |> std/store:stored { cfg.scenario: 8, cfg.which: 0 }
| `fanout` _ |> std/store:stored { cfg.scenario: 9, cfg.which: 0 }
| `bevy_strength_world` _ |> std/store:stored { cfg.scenario: 10, cfg.which: 0 }
| `boids` _ |> std/store:stored { cfg.scenario: 11, cfg.which: 0 }
| `boids_fused` _ |> std/store:stored { cfg.scenario: 12, cfg.which: 0 }
| `boids_f2` _ |> std/store:stored { cfg.scenario: 13, cfg.which: 0 }
| `boids_f4` _ |> std/store:stored { cfg.scenario: 14, cfg.which: 0 }
| no-match |> std/store:stored { cfg.scenario: 0, cfg.which: 0 }

tor take-value { a: string }
take-value = if(cfg.which == 1)
| then |> set-scenario(a)
| else |> std/string:from-page(text: a)
    | ok h |> std/string:parse-int(s: h)
        | ok v |> store-num(v)
        | err _ |> _
    | err _ |> _

tor handle-arg { a: string }
handle-arg = std/regex:match(a)
| `--scenario` _ |> std/store:stored { cfg.which: 1 }
| `--entities` _ |> std/store:stored { cfg.which: 2 }
| `--frames` _ |> std/store:stored { cfg.which: 3 }
| `--observers` _ |> std/store:stored { cfg.which: 4 }
| no-match |> take-value(a)

// ------------------------------------------------------------------- systems

// The baseline's World.init: every body gets a position, a velocity, health,
// and the every-tenth `act` flag that `sparse` filters on.
tor world-init {}
world-init = for(0..@as(usize, @intCast(cfg.entities)))
    ! each i |> std/store:insert(bodies) { px: @as(f32, @floatFromInt(i)), py: 0.0, vx: 1.0, vy: -1.0, hp: 1000, act: @as(i64, @intFromBool(i % 10 == 0)) }

tor integrate {}
integrate = std/store:query(bodies)
! query e |> std/store:stored { e.px: e.px + e.vx, e.py: e.py + e.vy }

// The baseline walks a 10%-dense index array; Koru has no index verb, so the
// filter is a guard and the sweep still visits every row. That gap is the
// measurement, not a detail to hide.
tor integrate-active {}
integrate-active = std/store:query(bodies)
! query e when e.act == 1 |> std/store:stored { e.px: e.px + e.vx, e.py: e.py + e.vy }

tor read-all {}
read-all = std/store:query(bodies)
! query e |> std/store:stored { acc.sink: acc.sink + @as(i64, @intFromFloat(e.px)) }

// `sparse` integrates only the rows whose `act` flag is set, so its sink must
// read the SAME subset — the zig baseline sums over its active index array and
// bevy filters `With<Active>`. Summing every row here made koru's sparse sink
// ~10x the other two: a real bug in this port, invisible until the anchors
// stopped sampling sixteen rows and the three numbers could be compared at all.
tor read-active {}
read-active = std/store:query(bodies)
! query e when e.act == 1 |> std/store:stored { acc.sink: acc.sink + @as(i64, @intFromFloat(e.px)) }

tor tick {}
tick = std/store:stored { acc.sink: acc.sink + 1 }

tor mark-init {}
mark-init = for(0..@as(usize, @intCast(cfg.entities)))
    ! each _ |> std/store:insert(marks) { on: 0 }

tor mark-set {}
mark-set = std/store:query(marks)
! query m |> std/store:stored { m.on: 1 }

tor mark-clear {}
mark-clear = std/store:query(marks)
! query m |> std/store:stored { m.on: 0 }

tor drain {}
drain = std/store:rule(bodies)
! row e |> std/store:take(bodies[e])
    | item _ |> _

tor count-rows {}
count-rows = std/store:query(bodies)
! query _ |> std/store:stored { acc.sink: acc.sink + 1 }

tor count-marks {}
count-marks = std/store:query(marks)
! query _ |> std/store:stored { acc.sink: acc.sink + 1 }

// --- fanout -----------------------------------------------------------------
//
// The baseline picks its victim by INDEX — `health[(frame*131 + i*17) % len]`.
// A cell names a row by handle, never by position, so that access is not
// spellable and no amount of cleverness makes it so. What the scenario is
// actually measuring is the observer fan-out per damage event, so the port
// keeps the event COUNT (entities/10 per frame) and the per-event observer
// work identical, and damages the every-tenth rows instead of pseudo-random
// ones. The sinks therefore differ across all three impls — bevy_ecs's
// already differs from the Zig baseline's for the same reason.

tor observe { value: i64 }
observe = for(0..@as(usize, @intCast(cfg.observers)))
    ! each o |> if ((((@as(u64, @bitCast(value)) ^ @as(u64, @intCast(o))) *% 0x9e3779b9) & 7) == 0)
        | then |> std/store:stored { acc.sink: acc.sink + value + @as(i64, @intCast(o)) }
        | else |> _

tor damage {}
damage = std/store:query(bodies)
! query e when e.act == 1 |> std/store:stored { e.hp: e.hp - 1 }
    |> observe(value: e.hp)

// --- bevy_strength_world ----------------------------------------------------

tor init-dyn {}
init-dyn = for(0..@as(usize, @intCast(@divTrunc(cfg.entities, 2))))
    ! each i |> std/store:insert(dyn) { px: @as(f32, @floatFromInt(i % 2048)), py: @as(f32, @floatFromInt((i * 7) % 2048)), vx: (@as(f32, @floatFromInt(i % 13)) - 6.0) * 0.01, vy: (@as(f32, @floatFromInt(i % 17)) - 8.0) * 0.01, ax: (@as(f32, @floatFromInt(i % 5)) - 2.0) * 0.001, ay: (@as(f32, @floatFromInt(i % 7)) - 3.0) * 0.001 }

tor init-parts {}
init-parts = for(0..@as(usize, @intCast(@divTrunc(cfg.entities, 4))))
    ! each i |> std/store:insert(parts) { px: @as(f32, @floatFromInt(i % 1024)), py: @as(f32, @floatFromInt((i * 11) % 1024)), vx: (@as(f32, @floatFromInt(i % 9)) - 4.0) * 0.03, vy: (@as(f32, @floatFromInt(i % 15)) - 7.0) * 0.03, life: 1000 + @as(i64, @intCast(i % 1000)), alive: 1 }

tor init-orbs {}
init-orbs = for(0..@as(usize, @intCast(cfg.entities - @divTrunc(cfg.entities, 2) - @divTrunc(cfg.entities, 4))))
    ! each i |> std/store:insert(orbs) { px: 0.0, py: 0.0, phase: @as(f32, @floatFromInt(i)) * 0.001, radius: 10.0 + @as(f32, @floatFromInt(i % 100)), speed: 0.001 + @as(f32, @floatFromInt(i % 11)) * 0.0001 }

tor step-dyn {}
step-dyn = std/store:query(dyn)
! query d |> std/store:stored { d.vx: (d.vx + d.ax) * 0.999, d.vy: (d.vy + d.ay) * 0.999 }
    |> std/store:stored { d.px: d.px + d.vx, d.py: d.py + d.vy }
    |> std/store:stored { d.vx: if (d.px < 0.0 or d.px > 2048.0) -d.vx * 0.8 else d.vx, d.vy: if (d.py < 0.0 or d.py > 2048.0) -d.vy * 0.8 else d.vy }
    |> std/store:stored { d.px: @min(@max(d.px, 0.0), 2048.0), d.py: @min(@max(d.py, 0.0), 2048.0) }
    |> std/store:stored { acc.sink: acc.sink + @as(i64, @intFromFloat(@abs(d.px))) * 31 + @as(i64, @intFromFloat(@abs(d.py))) * 17 }

tor step-parts {}
step-parts = std/store:query(parts)
! query p when p.alive == 1 |> std/store:stored { p.px: p.px + p.vx, p.py: p.py + p.vy, p.life: p.life - 1 }
    |> std/store:stored { p.alive: if (p.life <= 0) @as(i64, 0) else @as(i64, 1) }
    |> std/store:stored { acc.sink: acc.sink + @as(i64, @intFromFloat(@abs(p.px))) * 31 + @as(i64, @intFromFloat(@abs(p.py))) * 17 }

tor step-orbs {}
step-orbs = std/store:query(orbs)
! query o |> std/store:stored { o.phase: o.phase + o.speed }
    |> std/store:stored { o.px: o.radius * @cos(o.phase), o.py: o.radius * @sin(o.phase) }
    |> std/store:stored { acc.sink: acc.sink + @as(i64, @intFromFloat(@abs(o.px))) * 31 + @as(i64, @intFromFloat(@abs(o.py))) * 17 }

// --- boids ------------------------------------------------------------------
//
// Unity DOTS `BoidSystem.cs`, ported. The algorithm is theirs and the constants
// are theirs unscaled — CellRadius 8, weights 1/1/2, ObstacleAversionDistance
// 30, MoveSpeed 25 — over a 256-unit cube, which makes the grid exactly 32^3.
//
// This is the scenario the harness had no answer to. `combat_world`'s entry in
// the README says a spatial index is the first thing a borrowed ECS workload
// asked for that std/store cannot express; boids asks for the same thing and
// gets `std/grid`, a static positionally-addressed table declared beside the
// store rather than a collection the world holds.
//
// FOUR PHASES per frame, DOTS' own decomposition:
//   clear    — every cell, unconditionally (DOTS reallocates a hash map instead)
//   scatter  — each boid folds its heading and position into its cell
//   resolve  — each occupied cell averages, then finds its nearest target and
//              obstacle. This is DOTS' MergeCells, and it is per CELL: it is
//              the pass that needs a sweep to WRITE the cell it is visiting.
//   steer    — each boid reads its cell's aggregate and turns
//
// TWO DELIBERATE DEVIATIONS from the sample, both stated rather than hidden:
//   - a dense bounded grid instead of a sparse hash map, so positions clamp and
//     the clear pass exists;
//   - the accumulation here is CORRECT. DOTS' MergeCells.ExecuteNext reads
//     `cellAlignment[cellIndex] += cellAlignment[cellIndex]`, doubling the
//     accumulator instead of adding the member. That is a long-standing bug in
//     the sample; the surrounding comments describe the sum this port does.
//
// THE STEERING IS ENORMOUS and that is the finding, not an accident of style.
// The store has no expression-local binding, so every intermediate a register
// would hold in Zig or Rust is either recomputed inline or spilled to a column.
// This port does both: `tf*`/`nh*` carry the vectors across stages, and within
// a stage a shared subexpression is written out per component and left to LLVM
// to CSE. 12.7k characters of steering came out of ~40 lines of C#.
//
// The stages never read a column they write in another component, so the port
// does not depend on whether a multi-field write block is simultaneous or
// sequential — which is as well, because std/store and std/grid currently
// disagree about that.

tor flock-init {}
flock-init = for(0..@as(usize, @intCast(cfg.entities)))
    ! each i |> std/store:insert(flock) { px: @as(f32, @floatFromInt(i % 256)), py: @as(f32, @floatFromInt((i / 256) % 256)), pz: @as(f32, @floatFromInt((i / 65536) % 256)), fx: @as(f32, @floatFromInt(i % 13)) - 6.0, fy: @as(f32, @floatFromInt(i % 17)) - 8.0, fz: @as(f32, @floatFromInt(i % 7)) - 3.0, cell: 0, tfx: 0.0, tfy: 0.0, tfz: 0.0, nhx: 0.0, nhy: 0.0, nhz: 0.0 }

// The seeded heading is normalized in its own pass rather than inside the
// insert block, so the insert stays a statement of the data.
tor flock-normalize {}
flock-normalize = std/store:query(flock)
! query b |> std/store:stored { b.nhx: (if ((b.fx * b.fx + b.fy * b.fy + b.fz * b.fz) > 1.1754944e-38) b.fx * (1.0 / @sqrt((b.fx * b.fx + b.fy * b.fy + b.fz * b.fz))) else 0.0), b.nhy: (if ((b.fx * b.fx + b.fy * b.fy + b.fz * b.fz) > 1.1754944e-38) b.fy * (1.0 / @sqrt((b.fx * b.fx + b.fy * b.fy + b.fz * b.fz))) else 0.0), b.nhz: (if ((b.fx * b.fx + b.fy * b.fy + b.fz * b.fz) > 1.1754944e-38) b.fz * (1.0 / @sqrt((b.fx * b.fx + b.fy * b.fy + b.fz * b.fz))) else 0.0) }
    |> std/store:stored { b.fx: b.nhx, b.fy: b.nhy, b.fz: b.nhz }

tor frame-actors {}
frame-actors = std/store:stored { fr.t0x: @as(f32, @floatFromInt(@mod(frn.n * 3, 256))), fr.t0y: 128.0, fr.t0z: @as(f32, @floatFromInt(@mod(frn.n * 5, 256))), fr.t1x: @as(f32, @floatFromInt(@mod(frn.n * 7, 256))), fr.t1y: 160.0, fr.t1z: @as(f32, @floatFromInt(@mod(frn.n * 11, 256))), fr.obx: @as(f32, @floatFromInt(@mod(frn.n * 13, 256))), fr.oby: 128.0, fr.obz: @as(f32, @floatFromInt(@mod(frn.n * 17, 256))) }
    |> std/store:stored { frn.n: frn.n + 1 }

// Phase 1. Every cell, no guard: a cell that was occupied last frame and is
// empty this one must be cleared, so the sweep cannot filter on count.
tor grid-clear {}
grid-clear = std/grid:sweep(cells)
! sweep c |> std/grid:stored { c.count: 0, c.ax: 0.0, c.ay: 0.0, c.az: 0.0, c.sx: 0.0, c.sy: 0.0, c.sz: 0.0, c.ti: 0, c.od: 0.0 }

// Phase 2a. DOTS keeps `cellIndices` for exactly this reason: the hash is
// computed once and read again by the steer pass.
tor hash-boids {}
hash-boids = std/store:query(flock)
! query b |> std/store:stored { b.cell: (@as(i64, @min(@max(@as(i64, @intFromFloat(b.pz / 8.0)), 0), 31)) * 32 + @as(i64, @min(@max(@as(i64, @intFromFloat(b.py / 8.0)), 0), 31))) * 32 + @as(i64, @min(@max(@as(i64, @intFromFloat(b.px / 8.0)), 0), 31)) }

// Phase 2b. The scatter — a store sweep writing into a grid cell whose address
// comes out of the row. Float addition is not associative, so the visit order
// is part of the contract and all three arms fold in insertion order.
tor scatter {}
scatter = std/store:query(flock)
! query b |> std/grid:stored { cells[b.cell].count: cells[b.cell].count + 1, cells[b.cell].ax: cells[b.cell].ax + b.fx, cells[b.cell].ay: cells[b.cell].ay + b.fy, cells[b.cell].az: cells[b.cell].az + b.fz, cells[b.cell].sx: cells[b.cell].sx + b.px, cells[b.cell].sy: cells[b.cell].sy + b.py, cells[b.cell].sz: cells[b.cell].sz + b.pz }

// Phase 3. MergeCells: the sweep writes the cell it is standing on.
tor cell-resolve {}
cell-resolve = std/grid:sweep(cells)
! sweep c when c.count > 0 |> std/grid:stored { c.ti: if (((fr.t1x - (c.sx / @as(f32, @floatFromInt(c.count)))) * (fr.t1x - (c.sx / @as(f32, @floatFromInt(c.count)))) + (fr.t1y - (c.sy / @as(f32, @floatFromInt(c.count)))) * (fr.t1y - (c.sy / @as(f32, @floatFromInt(c.count)))) + (fr.t1z - (c.sz / @as(f32, @floatFromInt(c.count)))) * (fr.t1z - (c.sz / @as(f32, @floatFromInt(c.count))))) < ((fr.t0x - (c.sx / @as(f32, @floatFromInt(c.count)))) * (fr.t0x - (c.sx / @as(f32, @floatFromInt(c.count)))) + (fr.t0y - (c.sy / @as(f32, @floatFromInt(c.count)))) * (fr.t0y - (c.sy / @as(f32, @floatFromInt(c.count)))) + (fr.t0z - (c.sz / @as(f32, @floatFromInt(c.count)))) * (fr.t0z - (c.sz / @as(f32, @floatFromInt(c.count)))))) 1 else 0, c.od: @sqrt(((fr.obx - (c.sx / @as(f32, @floatFromInt(c.count)))) * (fr.obx - (c.sx / @as(f32, @floatFromInt(c.count)))) + (fr.oby - (c.sy / @as(f32, @floatFromInt(c.count)))) * (fr.oby - (c.sy / @as(f32, @floatFromInt(c.count)))) + (fr.obz - (c.sz / @as(f32, @floatFromInt(c.count)))) * (fr.obz - (c.sz / @as(f32, @floatFromInt(c.count)))))) }

// Phase 4, in stages, because the intermediates need somewhere to live.

tor steer-align {}
steer-align = std/store:query(flock)
! query b |> std/store:stored { b.tfx: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0), b.tfy: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0), b.tfz: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0) }

tor steer-separate {}
steer-separate = std/store:query(flock)
! query b |> std/store:stored { b.tfx: b.tfx + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0), b.tfy: b.tfy + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0), b.tfz: b.tfz + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0) }

tor steer-target {}
steer-target = std/store:query(flock)
! query b |> std/store:stored { b.tfx: b.tfx + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0), b.tfy: b.tfy + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0), b.tfz: b.tfz + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0) }

tor steer-avoid {}
steer-avoid = std/store:query(flock)
! query b |> std/store:stored { b.nhx: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.obx + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.px - fr.obx) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.px) else (if ((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz) > 1.1754944e-38) b.tfx * (1.0 / @sqrt((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz))) else 0.0), b.nhy: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.oby + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.py - fr.oby) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.py) else (if ((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz) > 1.1754944e-38) b.tfy * (1.0 / @sqrt((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz))) else 0.0), b.nhz: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.obz + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.pz - fr.obz) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.pz) else (if ((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz) > 1.1754944e-38) b.tfz * (1.0 / @sqrt((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz))) else 0.0) }

tor steer-heading {}
steer-heading = std/store:query(flock)
! query b |> std/store:stored { b.tfx: (if (((b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz))) > 1.1754944e-38) (b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) * (1.0 / @sqrt(((b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz))))) else 0.0), b.tfy: (if (((b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz))) > 1.1754944e-38) (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) * (1.0 / @sqrt(((b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz))))) else 0.0), b.tfz: (if (((b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz))) > 1.1754944e-38) (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz)) * (1.0 / @sqrt(((b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz))))) else 0.0) }

tor steer-move {}
steer-move = std/store:query(flock)
! query b |> std/store:stored { b.fx: b.tfx, b.fy: b.tfy, b.fz: b.tfz, b.px: b.px + b.tfx * (25.0 * @as(f32, 1.0 / 60.0)), b.py: b.py + b.tfy * (25.0 * @as(f32, 1.0 / 60.0)), b.pz: b.pz + b.tfz * (25.0 * @as(f32, 1.0 / 60.0)) }

tor steer-clamp {}
steer-clamp = std/store:query(flock)
! query b |> std/store:stored { b.px: if (b.px < 0.0) 0.0 else (if (b.px > 255.999) 255.999 else b.px), b.py: if (b.py < 0.0) 0.0 else (if (b.py > 255.999) 255.999 else b.py), b.pz: if (b.pz < 0.0) 0.0 else (if (b.pz > 255.999) 255.999 else b.pz) }

// THE SAME SEVEN WRITES AS ONE PASS. `boids` runs them as seven traversals,
// one write each; this runs them as one traversal with seven chained writes,
// which is the shape `step-dyn` uses and the shape a reader would expect to be
// faster. It is measurably slower and we do not yet know why, so both are here
// and both are runnable. Identical arithmetic, identical checksum.
tor steer-fused {}
steer-fused = std/store:query(flock)
! query b |> std/store:stored { b.tfx: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0), b.tfy: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0), b.tfz: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0) }
    |> std/store:stored { b.tfx: b.tfx + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0), b.tfy: b.tfy + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0), b.tfz: b.tfz + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0) }
    |> std/store:stored { b.tfx: b.tfx + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0), b.tfy: b.tfy + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0), b.tfz: b.tfz + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0) }
    |> std/store:stored { b.nhx: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.obx + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.px - fr.obx) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.px) else (if ((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz) > 1.1754944e-38) b.tfx * (1.0 / @sqrt((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz))) else 0.0), b.nhy: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.oby + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.py - fr.oby) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.py) else (if ((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz) > 1.1754944e-38) b.tfy * (1.0 / @sqrt((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz))) else 0.0), b.nhz: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.obz + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.pz - fr.obz) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.pz) else (if ((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz) > 1.1754944e-38) b.tfz * (1.0 / @sqrt((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz))) else 0.0) }
    |> std/store:stored { b.tfx: (if (((b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz))) > 1.1754944e-38) (b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) * (1.0 / @sqrt(((b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz))))) else 0.0), b.tfy: (if (((b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz))) > 1.1754944e-38) (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) * (1.0 / @sqrt(((b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz))))) else 0.0), b.tfz: (if (((b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz))) > 1.1754944e-38) (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz)) * (1.0 / @sqrt(((b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (b.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (b.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (b.nhz - b.fz))))) else 0.0) }
    |> std/store:stored { b.fx: b.tfx, b.fy: b.tfy, b.fz: b.tfz, b.px: b.px + b.tfx * (25.0 * @as(f32, 1.0 / 60.0)), b.py: b.py + b.tfy * (25.0 * @as(f32, 1.0 / 60.0)), b.pz: b.pz + b.tfz * (25.0 * @as(f32, 1.0 / 60.0)) }
    |> std/store:stored { b.px: if (b.px < 0.0) 0.0 else (if (b.px > 255.999) 255.999 else b.px), b.py: if (b.py < 0.0) 0.0 else (if (b.py > 255.999) 255.999 else b.py), b.pz: if (b.pz < 0.0) 0.0 else (if (b.pz > 255.999) 255.999 else b.pz) }

tor boid-frame-fused {}
boid-frame-fused = frame-actors() |> grid-clear() |> hash-boids() |> scatter() |> cell-resolve()
    |> steer-fused()

tor steer-f2 {}
steer-f2 = std/store:query(flock)
! query b |> std/store:stored { b.tfx: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0), b.tfy: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0), b.tfz: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0) }
    |> std/store:stored { b.tfx: b.tfx + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0), b.tfy: b.tfy + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0), b.tfz: b.tfz + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0) }

tor boid-frame-f2 {}
boid-frame-f2 = frame-actors() |> grid-clear() |> hash-boids() |> scatter() |> cell-resolve()
    |> steer-f2() |> steer-target() |> steer-avoid() |> steer-heading() |> steer-move() |> steer-clamp()

tor steer-f4 {}
steer-f4 = std/store:query(flock)
! query b |> std/store:stored { b.tfx: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0), b.tfy: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0), b.tfz: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0) }
    |> std/store:stored { b.tfx: b.tfx + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0), b.tfy: b.tfy + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0), b.tfz: b.tfz + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0) }
    |> std/store:stored { b.tfx: b.tfx + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0), b.tfy: b.tfy + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0), b.tfz: b.tfz + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0) }
    |> std/store:stored { b.nhx: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.obx + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.px - fr.obx) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.px) else (if ((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz) > 1.1754944e-38) b.tfx * (1.0 / @sqrt((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz))) else 0.0), b.nhy: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.oby + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.py - fr.oby) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.py) else (if ((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz) > 1.1754944e-38) b.tfy * (1.0 / @sqrt((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz))) else 0.0), b.nhz: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.obz + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.pz - fr.obz) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.pz) else (if ((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz) > 1.1754944e-38) b.tfz * (1.0 / @sqrt((b.tfx * b.tfx + b.tfy * b.tfy + b.tfz * b.tfz))) else 0.0) }

tor boid-frame-f4 {}
boid-frame-f4 = frame-actors() |> grid-clear() |> hash-boids() |> scatter() |> cell-resolve()
    |> steer-f4() |> steer-heading() |> steer-move() |> steer-clamp()

tor boid-frame {}
boid-frame = frame-actors() |> grid-clear() |> hash-boids() |> scatter() |> cell-resolve()
    |> steer-align() |> steer-separate() |> steer-target() |> steer-avoid()
    |> steer-heading() |> steer-move() |> steer-clamp()

// The checksum reads back outside the timed region, as `dense` does.
tor read-flock {}
read-flock = std/store:query(flock)
! query b |> std/store:stored { acc.sink: acc.sink + @as(i64, @intFromFloat(@abs(b.px))) * 31 + @as(i64, @intFromFloat(@abs(b.py))) * 17 + @as(i64, @intFromFloat(@abs(b.pz))) * 13 }

// ----------------------------------------------------------------- scenarios

tor s-dense {}
s-dense = world-init() |> for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> integrate()

tor s-sparse {}
s-sparse = world-init() |> for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> integrate-active()

// The read IS the workload here, so this one accumulates inside the timing.
tor s-query-get {}
s-query-get = world-init() |> for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> read-all()

tor s-schedule-empty {}
s-schedule-empty = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> tick()

// Koru has no batch-insert verb, so `spawn_batch` IS `spawn` — the same
// statement the Zig baseline makes by aliasing the two.
tor s-spawn {}
s-spawn = world-init()

tor s-despawn {}
s-despawn = world-init() |> drain()

tor s-add-remove {}
s-add-remove = mark-init() |> mark-set() |> mark-clear()

tor s-fanout {}
s-fanout = world-init() |> for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> damage()

tor strength-frame {}
strength-frame = step-dyn() |> step-parts() |> step-orbs()

// Init is OUTSIDE the timed region for this scenario, so `s-boids` is the
// frame loop and nothing else. The older rows time their world construction;
// boids does not, and the three arms agree on that.
tor s-boids {}
s-boids = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> boid-frame()

tor s-boids-fused {}
s-boids-fused = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> boid-frame-fused()

tor s-boids-f2 {}
s-boids-f2 = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> boid-frame-f2()

tor s-boids-f4 {}
s-boids-f4 = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> boid-frame-f4()

tor s-bevy-strength {}
s-bevy-strength = init-dyn() |> init-parts() |> init-orbs()
    |> for(0..@as(usize, @intCast(cfg.frames)))
        ! each _ |> strength-frame()

// ------------------------------------------------------------------ dispatch
//
// Flat, one guarded arm per scenario. Nesting eleven `if`s would bury the
// last one eleven levels deep for no gain.

tor run-dense {}
run-dense = if(cfg.scenario == 1)
| then |> s-dense()
| else |> _
tor run-sparse {}
run-sparse = if(cfg.scenario == 2)
| then |> s-sparse()
| else |> _
tor run-query-get {}
run-query-get = if(cfg.scenario == 3)
| then |> s-query-get()
| else |> _
tor run-schedule-empty {}
run-schedule-empty = if(cfg.scenario == 4)
| then |> s-schedule-empty()
| else |> _
tor run-spawn {}
run-spawn = if(cfg.scenario == 5)
| then |> s-spawn()
| else |> _
tor run-spawn-batch {}
run-spawn-batch = if(cfg.scenario == 6)
| then |> s-spawn()
| else |> _
tor run-despawn {}
run-despawn = if(cfg.scenario == 7)
| then |> s-despawn()
| else |> _
tor run-add-remove {}
run-add-remove = if(cfg.scenario == 8)
| then |> s-add-remove()
| else |> _
tor run-fanout {}
run-fanout = if(cfg.scenario == 9)
| then |> s-fanout()
| else |> _
tor run-bevy-strength {}
run-bevy-strength = if(cfg.scenario == 10)
| then |> s-bevy-strength()
| else |> _

tor run-boids {}
run-boids = if(cfg.scenario == 11)
| then |> s-boids()
| else |> _

tor run-boids-fused {}
run-boids-fused = if(cfg.scenario == 12)
| then |> s-boids-fused()
| else |> _

tor run-boids-f2 {}
run-boids-f2 = if(cfg.scenario == 13)
| then |> s-boids-f2()
| else |> _

tor run-boids-f4 {}
run-boids-f4 = if(cfg.scenario == 14)
| then |> s-boids-f4()
| else |> _

tor run {}
run = run-dense() |> run-sparse() |> run-query-get() |> run-schedule-empty()
    |> run-spawn() |> run-spawn-batch() |> run-despawn() |> run-add-remove()
    |> run-fanout() |> run-bevy-strength() |> run-boids() |> run-boids-fused() |> run-boids-f2() |> run-boids-f4()

// -------------------------------------------------------------- the checksum
//
// Untimed. `query_get` and `schedule_empty` already carry their own sink, so
// their arms are silent.

// Everything a scenario must build BEFORE the clock starts. Only boids uses
// it; the older rows deliberately keep their construction inside the timed
// region and the README says so.
tor prep {}
prep = if(cfg.scenario >= 11 and cfg.scenario <= 14)
| then |> flock-init() |> flock-normalize()
| else |> _

tor fin-dense {}
fin-dense = if(cfg.scenario == 1)
| then |> read-all()
| else |> _
tor fin-sparse {}
fin-sparse = if(cfg.scenario == 2)
| then |> read-active()
| else |> _
tor fin-spawn {}
fin-spawn = if(cfg.scenario == 5)
| then |> count-rows()
| else |> _
tor fin-spawn-batch {}
fin-spawn-batch = if(cfg.scenario == 6)
| then |> count-rows()
| else |> _
tor fin-despawn {}
fin-despawn = if(cfg.scenario == 7)
| then |> count-rows()
| else |> _
tor fin-add-remove {}
fin-add-remove = if(cfg.scenario == 8)
| then |> count-marks()
| else |> _

tor fin-boids {}
fin-boids = if(cfg.scenario >= 11 and cfg.scenario <= 14)
| then |> read-flock()
| else |> _

tor finish {}
finish = fin-dense() |> fin-sparse() |> fin-spawn() |> fin-spawn-batch()
    |> fin-despawn() |> fin-add-remove() |> fin-boids()
// `fanout` and `bevy_strength_world` accumulate their own sink as the
// workload runs, exactly as the baseline does — no read-back arm.

// ---------------------------------------------------------------- the report

tor name-dense {}
name-dense = if(cfg.scenario == 1)
| then |> std/io:print("dense")
| else |> _
tor name-sparse {}
name-sparse = if(cfg.scenario == 2)
| then |> std/io:print("sparse")
| else |> _
tor name-query-get {}
name-query-get = if(cfg.scenario == 3)
| then |> std/io:print("query_get")
| else |> _
tor name-schedule-empty {}
name-schedule-empty = if(cfg.scenario == 4)
| then |> std/io:print("schedule_empty")
| else |> _
tor name-spawn {}
name-spawn = if(cfg.scenario == 5)
| then |> std/io:print("spawn")
| else |> _
tor name-spawn-batch {}
name-spawn-batch = if(cfg.scenario == 6)
| then |> std/io:print("spawn_batch")
| else |> _
tor name-despawn {}
name-despawn = if(cfg.scenario == 7)
| then |> std/io:print("despawn")
| else |> _
tor name-add-remove {}
name-add-remove = if(cfg.scenario == 8)
| then |> std/io:print("add_remove")
| else |> _
tor name-fanout {}
name-fanout = if(cfg.scenario == 9)
| then |> std/io:print("fanout")
| else |> _
tor name-bevy-strength {}
name-bevy-strength = if(cfg.scenario == 10)
| then |> std/io:print("bevy_strength_world")
| else |> _

tor name-boids {}
name-boids = if(cfg.scenario == 11)
| then |> std/io:print("boids")
| else |> _

tor name-boids-fused {}
name-boids-fused = if(cfg.scenario == 12)
| then |> std/io:print("boids_fused")
| else |> _

tor name-boids-f2 {}
name-boids-f2 = if(cfg.scenario == 13)
| then |> std/io:print("boids_f2")
| else |> _

tor name-boids-f4 {}
name-boids-f4 = if(cfg.scenario == 14)
| then |> std/io:print("boids_f4")
| else |> _

tor emit { ns: i64 }
emit = std/io:print("{\"impl\":\"koru_store\",\"scenario\":\"")
    |> name-dense() |> name-sparse() |> name-query-get() |> name-schedule-empty()
    |> name-spawn() |> name-spawn-batch() |> name-despawn() |> name-add-remove()
    |> name-fanout() |> name-bevy-strength() |> name-boids() |> name-boids-fused() |> name-boids-f2() |> name-boids-f4()
    |> std/io:print.ln("\",\"entities\":{{ cfg.entities:d }},\"frames\":{{ cfg.frames:d }},\"observers\":{{ cfg.observers:d }},\"elapsed_ns\":{{ ns:d }},\"sink\":{{ acc.sink:d }}}")

// -------------------------------------------------------------------- driver

std/args:count(): n |> for(1..n)
! each i |> std/args:get(index: i)
    | arg a |> handle-arg(a)
    | out-of-bounds |> _

if(cfg.scenario == 0)
| then |> std/io:eprint.ln("koru_store: unknown or unimplemented --scenario")
| else |> prep() |> std/time:now(): t0 |> run() |> std/time:elapsed(start: t0): d |> finish()
    |> emit(ns: @as(i64, @intCast(d.ns)))
