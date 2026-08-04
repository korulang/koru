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
[unsafe(bounds)]std/grid:new(cells, size: 32768) { count: 0[i64], ax: 0.0[f32], ay: 0.0[f32], az: 0.0[f32], sx: 0.0[f32], sy: 0.0[f32], sz: 0.0[f32], ti: 0[i64], od: 0.0[f32] }

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

// Per-phase accumulators for `boids_phase`, the instrumented twin of `boids`.
// Nanoseconds, summed over frames. Written only by that scenario.
std/store:new(ph) { pact: 0[i64], pclr: 0[i64], phsh: 0[i64], psct: 0[i64], pres: 0[i64], pstg: 0[i64] }

// `archetype_churn_world` is the scenario that tests a RULING rather than
// adding coverage: Koru has no archetypes, and the claim is that it does not
// need them. A component is a PRESENCE COLUMN, and a "query over a changing
// component set" is a GUARDED SWEEP. bevy's five markers — Idle, Seeking,
// Attacking, Stunned, Dead — are mutually exclusive, since every transition
// removes the old marker as it inserts the new, so they are ONE `st` column
// rather than five presence flags.
//
// `dmg` is `Changed<Health>`. Nothing but the attack writes hp, so "changed
// this frame" is "damaged this frame", and the checksum sweep clears the flag
// the way a change tick ages out.
std/store:new(agents, capacity: 100000) { aid: i64, hp: i64, st: i64, tgt: i64, cd: i64, stun: i64, dmg: i64 }
std/store:new(ch) { frame: 0[i64], csum: 0[i64], trans: 0[i64], dmge: 0[i64], deaths: 0[i64] }

// THE INDEX->HANDLE BRIDGE, and it is the interesting part of this port.
//
// bevy holds `ChurnEntities(Vec<Entity>)` and reaches its victim by POSITION:
// `entities.0[(target + id*13) % count]`. The `fanout` note above says a row is
// named by handle and never by position, so that access "is not spellable and
// no amount of cleverness makes it so". THAT IS WRONG, and this is the
// counterexample: a GRID is positionally addressed, so a grid whose cells hold
// handles is exactly the missing `Vec<Entity>`. Position -> handle -> row, and
// 690_249 already lowers a read nested inside a write's row address.
std/grid:new(xref, size: 100000) { h: 0[i64] }

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
| `archetype_churn_world` _ |> std/store:stored { cfg.scenario: 25, cfg.which: 0 }
| `combat_world` _ |> std/store:stored { cfg.scenario: 26, cfg.which: 0 }
| `boids` _ |> std/store:stored { cfg.scenario: 11, cfg.which: 0 }
| `boids_fused` _ |> std/store:stored { cfg.scenario: 12, cfg.which: 0 }
| `boids_f2` _ |> std/store:stored { cfg.scenario: 13, cfg.which: 0 }
| `boids_f4` _ |> std/store:stored { cfg.scenario: 14, cfg.which: 0 }
| `boids_split` _ |> std/store:stored { cfg.scenario: 15, cfg.which: 0 }
| `boids_helpers` _ |> std/store:stored { cfg.scenario: 23, cfg.which: 0 }
| `boids_fold` _ |> std/store:stored { cfg.scenario: 24, cfg.which: 0 }
| `boids_phase` _ |> std/store:stored { cfg.scenario: 16, cfg.which: 0 }
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

// `world-init` with the handle table recorded beside it. Kept separate so the
// scenarios that never index by position do not pay for the grid write.
tor fanout-init {}
fanout-init = for(0..@as(usize, @intCast(cfg.entities)))
    ! each i |> std/store:insert(bodies) { px: @as(f32, @floatFromInt(i)), py: 0.0, vx: 1.0, vy: -1.0, hp: 1000, act: @as(i64, @intFromBool(i % 10 == 0)) }
        | row t |> std/grid:stored { bxref[i].h: t }
        | full |> _

// THESE MUST SIT ABOVE `drain`, AND THAT IS A SEMANTIC, NOT A STYLE CHOICE.
// `drain` is a `std/store:rule(bodies)` — a STANDING rule — and the emitted
// insert fires it for every insert site whose line is AFTER the rule's
// declaration (`if (__site_line > 214)`). `world-init` predates it and is
// untouched; this init was written below it at first, so every row it inserted
// was immediately `take`n. The handles it recorded were all stale: slot 0
// recycled with the generation climbing, and the whole scenario died on the
// 690_115 stale-handle trap. Declaration ORDER is part of the meaning here.
// The positionally-addressed twin of `bodies` — the baseline's bare array index,
// which a store row (named by handle, never by position) otherwise cannot offer.
[unsafe(bounds)]std/grid:new(bxref, size: 100000) { h: 0[i64] }
std/store:new(fw) { frame: 0[i64], last: 0[i64] }

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
// The baseline picks its victim by INDEX — `health[(frame*131 + i*17) % len]` —
// and folds the observer loop PER EVENT, at the post-decrement value. This port
// now does exactly that, through a grid of handles: the index names a cell, the
// cell holds the row's handle, and `bodies[bxref[i].h].hp` lowers.
//
// IT USED TO DAMAGE THE EVERY-TENTH ROWS INSTEAD, on the stated grounds that "a
// cell names a row by handle, never by position, so that access is not spellable
// and no amount of cleverness makes it so". That was wrong — pinned false by
// 690_253 — and the divergence it justified is now gone: this arm's sink agrees
// with the Zig baseline's exactly.
//
// The index->handle table is built inside the timed region, with the world, and
// that IS the honest cost of positional addressing here: the baseline indexes an
// array directly and pays nothing for it. Disclosed rather than hidden by moving
// it to `prep`.
//
// bevy_ecs still disagrees, and the reason recorded here for years was wrong. Its
// `damage_system` uses the SAME victim formula; what differs is the FOLD —
// `fanout_system` iterates `Changed<Health>`, a per-frame deduplicated SET, so an
// entity damaged ten times in a frame contributes once at its final value where
// zig and koru contribute ten times at ten values. Two anchors that disagree
// cannot arbitrate a third; that one is the next thing to settle.

tor observe { value: i64 }
observe = for(0..@as(usize, @intCast(cfg.observers)))
    ! each o |> if ((((@as(u64, @bitCast(value)) ^ @as(u64, @intCast(o))) *% 0x9e3779b9) & 7) == 0)
        | then |> std/store:stored { acc.sink: acc.sink + value + @as(i64, @intCast(o)) }
        | else |> _

// One damage EVENT, `entities/10` of them per frame. The victim address is
// respelled FOUR times for want of an expression-local binding.
//
// The third rung is not stylistic — it is a WALL. An indexed store read lowers
// in a write block and inside a write's ROW ADDRESS, but NOT in a call
// ARGUMENT: `observe(value: bodies[bxref[i].h].hp)` reaches the host as the
// literal text `bodies[...]` and the backend refuses with `use of undeclared
// identifier 'bodies'`. Same reach gap as `print.ln`, which does not run the
// lowering at all. So the value is parked in a column and passed from there.
// Pinned aspirationally as 690_254.
tor damage {}
damage = for(0..@as(usize, @intCast(@divTrunc(cfg.entities, 10))))
    ! each i |> std/store:stored { bodies[bxref[@as(usize, @intCast(@mod(fw.frame * 131 + @as(i64, @intCast(i)) * 17, cfg.entities)))].h].hp: bodies[bxref[@as(usize, @intCast(@mod(fw.frame * 131 + @as(i64, @intCast(i)) * 17, cfg.entities)))].h].hp - 1 }
        |> std/store:stored { fw.last: bodies[bxref[@as(usize, @intCast(@mod(fw.frame * 131 + @as(i64, @intCast(i)) * 17, cfg.entities)))].h].hp }
        |> observe(value: fw.last)

tor fanout-frame {}
fanout-frame = damage() |> std/store:stored { fw.frame: fw.frame + 1 }

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
! query b |> std/store:stored { b.px: @min(@max(b.px, 0.0), 255.999), b.py: @min(@max(b.py, 0.0), 255.999), b.pz: @min(@max(b.pz, 0.0), 255.999) }

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
    |> std/store:stored { b.px: @min(@max(b.px, 0.0), 255.999), b.py: @min(@max(b.py, 0.0), 255.999), b.pz: @min(@max(b.pz, 0.0), 255.999) }

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

// THE INTERMEDIATES AS CAPTURE SLOTS, not columns. `capture` is the
// expression-local binding this file's earlier note claimed the language did not
// have. It nests under an effect arm (670_013) and a store query arm is one, so
// the four steering vectors need never touch the store: one traversal, locals.
tor steer-capture {}
steer-capture = std/store:query(flock)
! query b |> capture { tfx: 0.0[f32], tfy: 0.0[f32], tfz: 0.0[f32], nhx: 0.0[f32], nhy: 0.0[f32], nhz: 0.0[f32] }
    ! as s |> captured { tfx: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0), tfy: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0), tfz: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0) }
        |> captured { tfx: s.tfx + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0), tfy: s.tfy + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0), tfz: s.tfz + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0) }
        |> captured { tfx: s.tfx + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0), tfy: s.tfy + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0), tfz: s.tfz + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0) }
        |> captured { nhx: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.obx + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.px - fr.obx) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.px) else (if ((s.tfx * s.tfx + s.tfy * s.tfy + s.tfz * s.tfz) > 1.1754944e-38) s.tfx * (1.0 / @sqrt((s.tfx * s.tfx + s.tfy * s.tfy + s.tfz * s.tfz))) else 0.0), nhy: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.oby + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.py - fr.oby) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.py) else (if ((s.tfx * s.tfx + s.tfy * s.tfy + s.tfz * s.tfz) > 1.1754944e-38) s.tfy * (1.0 / @sqrt((s.tfx * s.tfx + s.tfy * s.tfy + s.tfz * s.tfz))) else 0.0), nhz: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.obz + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.pz - fr.obz) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.pz) else (if ((s.tfx * s.tfx + s.tfy * s.tfy + s.tfz * s.tfz) > 1.1754944e-38) s.tfz * (1.0 / @sqrt((s.tfx * s.tfx + s.tfy * s.tfy + s.tfz * s.tfz))) else 0.0) }
        |> captured { tfx: (if (((b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz))) > 1.1754944e-38) (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) * (1.0 / @sqrt(((b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz))))) else 0.0), tfy: (if (((b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz))) > 1.1754944e-38) (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) * (1.0 / @sqrt(((b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz))))) else 0.0), tfz: (if (((b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz))) > 1.1754944e-38) (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) * (1.0 / @sqrt(((b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz))))) else 0.0) }
    | captured r |> std/store:stored { b.fx: r.tfx, b.fy: r.tfy, b.fz: r.tfz, b.px: b.px + r.tfx * (25.0 * @as(f32, 1.0 / 60.0)), b.py: b.py + r.tfy * (25.0 * @as(f32, 1.0 / 60.0)), b.pz: b.pz + r.tfz * (25.0 * @as(f32, 1.0 / 60.0)) }
        |> std/store:stored { b.px: @min(@max(b.px, 0.0), 255.999), b.py: @min(@max(b.py, 0.0), 255.999), b.pz: @min(@max(b.pz, 0.0), 255.999) }

// RED HERRING, PINNED. Identical arithmetic to `steer-capture`, but the clamp
// is folded into the SAME block instead of a second chained one.
//
// The reasoning that produced this variant: two chained `stored`s are two
// transactions, so px/py/pz are written unclamped, made observable, then
// written again -- three stores the emitted code does not need. Nothing in
// this program watches them (zero `watch`, zero `intercept`), and subscriptions
// are compiled into the write path, so the compiler KNOWS the observer set is
// empty at comptime and could fuse the two transactions itself. That is the
// fusion argument the atomicity ruling licenses.
//
// IT IS 2 ms SLOWER. 99.8 against 97.6, seven interleaved rounds, same
// checksum. The store-count gap to clang (14 vector stores per four boids in
// `steer_capture_event.handler` against clang's 6) is real and is NOT
// collectible this way: removing the second transaction makes the single body
// fatter, and this workload punishes fat bodies -- the same direction the
// fusion ladder shows, where `boids_f4` is last.
//
// So compiler-side transaction fusion is CONTRAINDICATED here, and this
// scenario exists to stop it being built on the strength of a store count.
// Unexplained, and deliberately not guessed at: the likely reading is that the
// extra stores are capture-slot SPILLS rather than column writes, which would
// make body size the cause and the store count a symptom.
tor steer-fold {}
steer-fold = std/store:query(flock)
! query b |> capture { tfx: 0.0[f32], tfy: 0.0[f32], tfz: 0.0[f32], nhx: 0.0[f32], nhy: 0.0[f32], nhz: 0.0[f32] }
    ! as s |> captured { tfx: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0), tfy: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0), tfz: 1.0 * (if (((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)) > 1.1754944e-38) (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (1.0 / @sqrt(((cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) * (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx) + (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) * (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy) + (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) * (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz)))) else 0.0) }
        |> captured { tfx: s.tfx + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0), tfy: s.tfy + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0), tfz: s.tfz + 1.0 * (if (((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)) > 1.1754944e-38) (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (1.0 / @sqrt(((b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) * (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx) + (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) * (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy) + (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) * (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz)))) else 0.0) }
        |> captured { tfx: s.tfx + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0), tfy: s.tfy + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0), tfz: s.tfz + 2.0 * (if ((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)) > 1.1754944e-38) ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * (1.0 / @sqrt((((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) * ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px) + ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) * ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py) + ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) * ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz)))) else 0.0) }
        |> captured { nhx: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.obx + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.px - fr.obx) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.px) else (if ((s.tfx * s.tfx + s.tfy * s.tfy + s.tfz * s.tfz) > 1.1754944e-38) s.tfx * (1.0 / @sqrt((s.tfx * s.tfx + s.tfy * s.tfy + s.tfz * s.tfz))) else 0.0), nhy: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.oby + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.py - fr.oby) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.py) else (if ((s.tfx * s.tfx + s.tfy * s.tfy + s.tfz * s.tfz) > 1.1754944e-38) s.tfy * (1.0 / @sqrt((s.tfx * s.tfx + s.tfy * s.tfy + s.tfz * s.tfz))) else 0.0), nhz: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.obz + (if (((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)) > 1.1754944e-38) (b.pz - fr.obz) * (1.0 / @sqrt(((b.px - fr.obx) * (b.px - fr.obx) + (b.py - fr.oby) * (b.py - fr.oby) + (b.pz - fr.obz) * (b.pz - fr.obz)))) else 0.0) * 30.0) - b.pz) else (if ((s.tfx * s.tfx + s.tfy * s.tfy + s.tfz * s.tfz) > 1.1754944e-38) s.tfz * (1.0 / @sqrt((s.tfx * s.tfx + s.tfy * s.tfy + s.tfz * s.tfz))) else 0.0) }
        |> captured { tfx: (if (((b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz))) > 1.1754944e-38) (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) * (1.0 / @sqrt(((b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz))))) else 0.0), tfy: (if (((b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz))) > 1.1754944e-38) (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) * (1.0 / @sqrt(((b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz))))) else 0.0), tfz: (if (((b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz))) > 1.1754944e-38) (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) * (1.0 / @sqrt(((b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) * (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)) + (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) * (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)) + (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) * (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz))))) else 0.0) }
    | captured r |> std/store:stored { b.fx: r.tfx, b.fy: r.tfy, b.fz: r.tfz, b.px: @min(@max(b.px + r.tfx * (25.0 * @as(f32, 1.0 / 60.0)), 0.0), 255.999), b.py: @min(@max(b.py + r.tfy * (25.0 * @as(f32, 1.0 / 60.0)), 0.0), 255.999), b.pz: @min(@max(b.pz + r.tfz * (25.0 * @as(f32, 1.0 / 60.0)), 0.0), 255.999) }

tor boid-frame-fold {}
boid-frame-fold = frame-actors() |> grid-clear() |> hash-boids() |> scatter() |> cell-resolve()
    |> steer-fold()

tor boid-frame-capture {}
boid-frame-capture = frame-actors() |> grid-clear() |> hash-boids() |> scatter() |> cell-resolve()
    |> steer-capture()

// CALLS ARE NOT EXPRESSIONS (KORU104) — a helper's result is bound in the chain
// and then spent, which is the same shape 690_131 uses for its swap. So the
// short form is not "inline less", it is "bind more".
tor nsafe-c { c: f32, x: f32, y: f32, z: f32 } -> f32
nsafe-c -> if (x * x + y * y + z * z > 1.1754944e-38) c * (1.0 / @sqrt(x * x + y * y + z * z)) else 0.0

tor steer-helpers {}
steer-helpers = std/store:query(flock)
! query b |> capture { tfx: 0.0[f32], tfy: 0.0[f32], tfz: 0.0[f32], nhx: 0.0[f32], nhy: 0.0[f32], nhz: 0.0[f32], wx: 0.0[f32], wy: 0.0[f32], wz: 0.0[f32] }
    ! as s |> captured { wx: (cells[b.cell].ax / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fx), wy: (cells[b.cell].ay / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fy), wz: (cells[b.cell].az / @as(f32, @floatFromInt(cells[b.cell].count)) - b.fz) }
        |> nsafe-c(c: s.wx, x: s.wx, y: s.wy, z: s.wz): ax
        |> nsafe-c(c: s.wy, x: s.wx, y: s.wy, z: s.wz): ay
        |> nsafe-c(c: s.wz, x: s.wx, y: s.wy, z: s.wz): az
        |> captured { tfx: 1.0 * ax, tfy: 1.0 * ay, tfz: 1.0 * az }
        |> captured { wx: (b.px * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sx), wy: (b.py * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sy), wz: (b.pz * @as(f32, @floatFromInt(cells[b.cell].count)) - cells[b.cell].sz) }
        |> nsafe-c(c: s.wx, x: s.wx, y: s.wy, z: s.wz): px
        |> nsafe-c(c: s.wy, x: s.wx, y: s.wy, z: s.wz): py
        |> nsafe-c(c: s.wz, x: s.wx, y: s.wy, z: s.wz): pz
        |> captured { tfx: s.tfx + 1.0 * px, tfy: s.tfy + 1.0 * py, tfz: s.tfz + 1.0 * pz }
        |> captured { wx: ((if (cells[b.cell].ti == 0) fr.t0x else fr.t1x) - b.px), wy: ((if (cells[b.cell].ti == 0) fr.t0y else fr.t1y) - b.py), wz: ((if (cells[b.cell].ti == 0) fr.t0z else fr.t1z) - b.pz) }
        |> nsafe-c(c: s.wx, x: s.wx, y: s.wy, z: s.wz): gx
        |> nsafe-c(c: s.wy, x: s.wx, y: s.wy, z: s.wz): gy
        |> nsafe-c(c: s.wz, x: s.wx, y: s.wy, z: s.wz): gz
        |> captured { tfx: s.tfx + 2.0 * gx, tfy: s.tfy + 2.0 * gy, tfz: s.tfz + 2.0 * gz }
        |> captured { wx: (b.px - fr.obx), wy: (b.py - fr.oby), wz: (b.pz - fr.obz) }
        |> nsafe-c(c: s.wx, x: s.wx, y: s.wy, z: s.wz): ox
        |> nsafe-c(c: s.wy, x: s.wx, y: s.wy, z: s.wz): oy
        |> nsafe-c(c: s.wz, x: s.wx, y: s.wy, z: s.wz): oz
        |> nsafe-c(c: s.tfx, x: s.tfx, y: s.tfy, z: s.tfz): tx
        |> nsafe-c(c: s.tfy, x: s.tfx, y: s.tfy, z: s.tfz): ty
        |> nsafe-c(c: s.tfz, x: s.tfx, y: s.tfy, z: s.tfz): tz
        |> captured { nhx: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.obx + ox * 30.0) - b.px) else tx, nhy: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.oby + oy * 30.0) - b.py) else ty, nhz: if ((cells[b.cell].od - 30.0) < 0.0) ((fr.obz + oz * 30.0) - b.pz) else tz }
        |> captured { wx: (b.fx + @as(f32, 1.0 / 60.0) * (s.nhx - b.fx)), wy: (b.fy + @as(f32, 1.0 / 60.0) * (s.nhy - b.fy)), wz: (b.fz + @as(f32, 1.0 / 60.0) * (s.nhz - b.fz)) }
        |> nsafe-c(c: s.wx, x: s.wx, y: s.wy, z: s.wz): nx
        |> nsafe-c(c: s.wy, x: s.wx, y: s.wy, z: s.wz): ny
        |> nsafe-c(c: s.wz, x: s.wx, y: s.wy, z: s.wz): nz
        |> captured { tfx: nx, tfy: ny, tfz: nz }
    | captured r |> std/store:stored { b.fx: r.tfx, b.fy: r.tfy, b.fz: r.tfz, b.px: b.px + r.tfx * (25.0 * @as(f32, 1.0 / 60.0)), b.py: b.py + r.tfy * (25.0 * @as(f32, 1.0 / 60.0)), b.pz: b.pz + r.tfz * (25.0 * @as(f32, 1.0 / 60.0)) }
        |> std/store:stored { b.px: @min(@max(b.px, 0.0), 255.999), b.py: @min(@max(b.py, 0.0), 255.999), b.pz: @min(@max(b.pz, 0.0), 255.999) }

tor boid-frame-helpers {}
boid-frame-helpers = frame-actors() |> grid-clear() |> hash-boids() |> scatter() |> cell-resolve()
    |> steer-helpers()

tor boid-frame {}
boid-frame = frame-actors() |> grid-clear() |> hash-boids() |> scatter() |> cell-resolve()
    |> steer-capture()

// The same steering with every intermediate routed through a store COLUMN
// instead of a capture slot, as seven separate passes. Kept because it is a rung
// of the ladder, not because anyone should write it this way.
tor boid-frame-split {}
boid-frame-split = frame-actors() |> grid-clear() |> hash-boids() |> scatter() |> cell-resolve()
    |> steer-align() |> steer-separate() |> steer-target() |> steer-avoid()
    |> steer-heading() |> steer-move() |> steer-clamp()

// `boids_phase` is `boids` with a monotonic read between every stage: the same
// six stages in the same order, the same arithmetic, the same checksum. The
// breakdown goes to stderr; the JSON line is unchanged in shape.
tor tp-actors {}
tp-actors = std/time:now(): t |> frame-actors() |> std/time:elapsed(start: t): d
    |> std/store:stored { ph.pact: ph.pact + @as(i64, @intCast(d.ns)) }

tor tp-clear {}
tp-clear = std/time:now(): t |> grid-clear() |> std/time:elapsed(start: t): d
    |> std/store:stored { ph.pclr: ph.pclr + @as(i64, @intCast(d.ns)) }

tor tp-hash {}
tp-hash = std/time:now(): t |> hash-boids() |> std/time:elapsed(start: t): d
    |> std/store:stored { ph.phsh: ph.phsh + @as(i64, @intCast(d.ns)) }

tor tp-scatter {}
tp-scatter = std/time:now(): t |> scatter() |> std/time:elapsed(start: t): d
    |> std/store:stored { ph.psct: ph.psct + @as(i64, @intCast(d.ns)) }

tor tp-resolve {}
tp-resolve = std/time:now(): t |> cell-resolve() |> std/time:elapsed(start: t): d
    |> std/store:stored { ph.pres: ph.pres + @as(i64, @intCast(d.ns)) }

tor tp-steer {}
tp-steer = std/time:now(): t |> steer-capture() |> std/time:elapsed(start: t): d
    |> std/store:stored { ph.pstg: ph.pstg + @as(i64, @intCast(d.ns)) }

tor boid-frame-phase {}
boid-frame-phase = tp-actors() |> tp-clear() |> tp-hash() |> tp-scatter() |> tp-resolve() |> tp-steer()

// `boids_mask` is `boids` with every grid read written `cells[@mod(b.cell, 32768)]`
// instead of `cells[b.cell]`. Identical arithmetic (the cell index is already in
// [0,32767] because positions clamp), identical checksum — the only difference is
// that the index is PROVABLY in range at the Zig level, so std/grid's `__koru_at`
// bounds check folds away instead of leaving a trap edge in the loop.









tor read-flock {}
read-flock = std/store:query(flock)
! query b |> std/store:stored { acc.sink: acc.sink + @as(i64, @intFromFloat(@abs(b.px))) * 31 + @as(i64, @intFromFloat(@abs(b.py))) * 17 + @as(i64, @intFromFloat(@abs(b.pz))) * 13 }

// --- archetype_churn_world --------------------------------------------------
//
// One sweep per bevy system, in bevy's chained order. Every sweep MUTATES THE
// COLUMN ITS OWN GUARD READS — the hazard the scenario exists to probe — and a
// sweep visits each row once, so a row transitions at most once per system.
//
// The systems are separate sweeps rather than one fused pass because bevy's
// `.chain()` inserts a sync point between systems: a transition made by an
// earlier system IS visible to a later one in the SAME frame. Measured, not
// assumed — at frame 0 with 1000 agents bevy reports 122 transitions, which is
// 91 idle->seeking plus the 31 of those that go on to seeking->attacking in the
// same frame. Fusing the sweeps would lose that and the checksum would say so.

tor churn-init {}
churn-init = for(0..@as(usize, @intCast(cfg.entities)))
    ! each i |> std/store:insert(agents) { aid: @as(i64, @intCast(i)), hp: 100 + @as(i64, @intCast(@mod(i, 200))), st: 0, tgt: 0, cd: 0, stun: 0, dmg: 0 }
        | row t |> std/grid:stored { xref[i].h: t }
        | full |> _

tor churn-idle-to-seeking {}
churn-idle-to-seeking = std/store:query(agents)
! query a when a.st == 0 and @mod(a.aid + ch.frame, 11) == 0
    |> std/store:stored { a.st: 1, a.tgt: @mod(a.aid * 17 + ch.frame, 100000) }
    |> std/store:stored { ch.trans: ch.trans + 1 }

tor churn-seeking-to-attacking {}
churn-seeking-to-attacking = std/store:query(agents)
! query a when a.st == 1 and @mod(a.aid + ch.frame, 3) == 0
    |> std/store:stored { a.st: 2, a.cd: 3 + @mod(a.aid, 7) }
    |> std/store:stored { ch.trans: ch.trans + 1 }

// The big one, and its size IS the finding. bevy decrements the cooldown, bails
// while it is still positive, and otherwise damages the row at
// `(target + id*13) % count` — reached here through the xref grid.
//
// THE VICTIM'S ADDRESS IS RESPELLED TEN TIMES. The store has no
// expression-local binding, so an intermediate Rust holds in a register has to
// be written out at every use, and a conditional effect becomes an `if` inside
// each written value rather than an early `continue`. This is the same cost the
// boids steering pays; it is stated rather than hidden.
tor churn-attack {}
churn-attack = std/store:query(agents)
! query a when a.st == 2 |> std/store:stored { a.cd: a.cd - 1 }
    |> std/store:stored { agents[xref[@as(usize, @intCast(@mod(a.tgt + a.aid * 13, cfg.entities)))].h].hp: if (a.cd <= 0 and agents[xref[@as(usize, @intCast(@mod(a.tgt + a.aid * 13, cfg.entities)))].h].st != 4) agents[xref[@as(usize, @intCast(@mod(a.tgt + a.aid * 13, cfg.entities)))].h].hp - 35 else agents[xref[@as(usize, @intCast(@mod(a.tgt + a.aid * 13, cfg.entities)))].h].hp }
    |> std/store:stored { agents[xref[@as(usize, @intCast(@mod(a.tgt + a.aid * 13, cfg.entities)))].h].dmg: if (a.cd <= 0 and agents[xref[@as(usize, @intCast(@mod(a.tgt + a.aid * 13, cfg.entities)))].h].st != 4) @as(i64, 1) else agents[xref[@as(usize, @intCast(@mod(a.tgt + a.aid * 13, cfg.entities)))].h].dmg }
    |> std/store:stored { ch.dmge: ch.dmge + (if (a.cd <= 0 and agents[xref[@as(usize, @intCast(@mod(a.tgt + a.aid * 13, cfg.entities)))].h].st != 4) @as(i64, 1) else @as(i64, 0)) }
    |> std/store:stored { ch.csum: ch.csum + (if (a.cd <= 0 and agents[xref[@as(usize, @intCast(@mod(a.tgt + a.aid * 13, cfg.entities)))].h].st != 4) agents[xref[@as(usize, @intCast(@mod(a.tgt + a.aid * 13, cfg.entities)))].h].hp * 31 + a.aid else @as(i64, 0)) }
    |> std/store:stored { a.st: if (a.cd <= 0) (if (@mod(a.aid, 23) == 0) @as(i64, 3) else @as(i64, 0)) else a.st, a.stun: if (a.cd <= 0 and @mod(a.aid, 23) == 0) 2 + @mod(a.aid, 5) else a.stun }
    |> std/store:stored { ch.trans: ch.trans + (if (a.cd <= 0) @as(i64, 1) else @as(i64, 0)) }

tor churn-stunned-to-idle {}
churn-stunned-to-idle = std/store:query(agents)
! query a when a.st == 3 |> std/store:stored { a.stun: a.stun - 1 }
    |> std/store:stored { a.st: if (a.stun <= 0) @as(i64, 0) else a.st }
    |> std/store:stored { ch.trans: ch.trans + (if (a.stun <= 0) @as(i64, 1) else @as(i64, 0)) }

tor churn-mark-dead {}
churn-mark-dead = std/store:query(agents)
! query a when a.st != 4 and a.hp <= 0 |> std/store:stored { a.st: 4 }
    |> std/store:stored { ch.trans: ch.trans + 1, ch.deaths: ch.deaths + 1 }

// No Dead filter, because bevy's `Changed<Health>` query has none: a row killed
// this frame still contributes the health it died at.
tor churn-checksum {}
churn-checksum = std/store:query(agents)
! query a when a.dmg == 1 |> std/store:stored { ch.csum: ch.csum + a.aid * 17 + a.hp }
    |> std/store:stored { a.dmg: 0 }

tor churn-advance {}
churn-advance = std/store:stored { ch.frame: ch.frame + 1 }

tor churn-frame {}
churn-frame = churn-idle-to-seeking() |> churn-seeking-to-attacking()
    |> churn-attack() |> churn-stunned-to-idle() |> churn-mark-dead()
    |> churn-checksum() |> churn-advance()

// --- combat_world -----------------------------------------------------------
//
// The scenario the harness had no answer to for the longest. It needs a SPATIAL
// INDEX whose cells hold a VARIABLE-LENGTH LIST, and a walk over that list that
// STOPS at the first hit. Every piece of that is now expressible:
//
//   bucket        -> an INTRUSIVE CHAIN. The grid cell holds the head handle,
//                    the enemy row carries `enext`. No collection type needed.
//   list order    -> the chain is built by sweeping enemies DESCENDING, so
//                    head-insertion reads back ASCENDING. This is load-bearing,
//                    not tidiness: the baseline appends enemies 0..n and BREAKS
//                    on the first hit, so a reversed walk picks a different
//                    victim and the sink diverges.
//   walk + break  -> `for(..., keep: ...)`. Before that existed the walk had to
//                    run its full bound with every iteration guarded into a
//                    no-op, costing the BOUND instead of the LENGTH.
//   row by index  -> a grid of handles (690_253).
//
// Oracle: zig_striped and bevy_ecs AGREE at 1838076, so unlike `fanout` this row
// has a real arbiter.
std/store:new(en, capacity: 10000) { ex: f32, ey: f32, ehp: i64, ealive: i64, enext: 0[i64] }
std/store:new(pr, capacity: 10000) { ppx: f32, ppy: f32, pvx: f32, pvy: f32, palive: i64 }
[unsafe(bounds)]std/grid:new(bkt, size: 4096) { head: 0[i64] }
[unsafe(bounds)]std/grid:new(exr, size: 10000) { h: 0[i64] }
std/store:new(cw) { cur: 0[i64], hit: 0[i64], now: 0[i64], lasthp: 0[i64], h: 0[i64], cell: 0[i64], alive: 0[i64] }

tor combat-init {}
combat-init = for(0..@as(usize, @intCast(@divTrunc(cfg.entities, 10))))
    ! each i |> std/store:insert(en) { ex: @as(f32, @floatFromInt((i * 37) % 1024)) + 0.5, ey: @as(f32, @floatFromInt((i * 91) % 1024)) + 0.5, ehp: 100, ealive: 1, enext: 0 }
        | row t |> std/grid:stored { exr[i].h: t }
        | full |> _

tor combat-init-pr {}
combat-init-pr = for(0..@as(usize, @intCast(@divTrunc(cfg.entities, 10))))
    ! each i |> std/store:insert(pr) { ppx: @as(f32, @floatFromInt((i * 37) % 1024)), ppy: @as(f32, @floatFromInt((i * 91) % 1024)), pvx: if (i % 2 == 0) 0.25 else -0.25, pvy: if (i % 3 == 0) 0.15 else -0.15, palive: 1 }
        | row _ |> _
        | full |> _

tor combat-move {}
combat-move = std/store:query(pr)
! query p when p.palive == 1 |> std/store:stored { p.ppx: p.ppx + p.pvx, p.ppy: p.ppy + p.pvy }

tor combat-clear {}
combat-clear = for(0..4096)
    ! each c |> std/grid:stored { bkt[c].head: 0 }

// DESCENDING, so the head-inserted chain reads ascending. The head write is
// guarded on `ealive` by an if-expression rather than a `when`, because the
// sweep must still visit dead rows to reach the live ones below them.
//
// THE INTERMEDIATES ARE PARKED IN COLUMNS, and not for readability. An indexed
// store read does not lower inside a GRID INDEX expression: written inline,
// `bkt[... en[exr[i].h].ex ...]` reaches the host as the literal text `en[...]`
// and the backend refuses with `use of undeclared identifier 'en'`. Same reach
// gap as a call argument (690_254) and `print.ln`. So the handle lands in `cw.h`
// and the cell index in `cw.cell` first, and every later rung addresses through
// those. It reads better this way, which is a consolation and not the reason.
tor combat-rebuild {}
combat-rebuild = for(0..@as(usize, @intCast(@divTrunc(cfg.entities, 10))))
    ! each k |> std/store:stored { cw.h: exr[@as(usize, @intCast(@divTrunc(cfg.entities, 10) - 1 - @as(i64, @intCast(k))))].h }
        |> std/store:stored { cw.cell: @as(i64, @min(@max(@as(i64, @intFromFloat(@floor(en[cw.h].ex / 16.0))), 0), 63)) + @as(i64, @min(@max(@as(i64, @intFromFloat(@floor(en[cw.h].ey / 16.0))), 0), 63)) * 64 }
        |> std/store:stored { cw.alive: en[cw.h].ealive }
        |> std/store:stored { en[cw.h].enext: bkt[@as(usize, @intCast(cw.cell))].head }
        |> std/grid:stored { bkt[@as(usize, @intCast(cw.cell))].head: if (cw.alive == 1) cw.h else bkt[@as(usize, @intCast(cw.cell))].head }

// The observer fan-out, fired only on a real hit. `observe` cannot be called
// conditionally from a chain, so the condition rides in as a parameter.
tor combat-observe { value: i64, fire: i64 }
combat-observe = for(0..@as(usize, @intCast(cfg.observers)))
    ! each o |> if (fire == 1 and (((@as(u64, @bitCast(value)) ^ @as(u64, @intCast(o))) *% 0x9e3779b9) & 7) == 0)
        | then |> std/store:stored { acc.sink: acc.sink + value + @as(i64, @intCast(o)) }
        | else |> _

// ONE STEP of the chain walk. `keep:` stops the loop at the first hit, so this
// runs once per enemy actually inspected — the length, not the bound.
tor combat-step { qx: f32, qy: f32 }
combat-step = std/store:stored { cw.now: if (en[cw.cur].ealive == 1 and (qx - en[cw.cur].ex) * (qx - en[cw.cur].ex) + (qy - en[cw.cur].ey) * (qy - en[cw.cur].ey) <= 4.0) @as(i64, 1) else @as(i64, 0) }
    |> std/store:stored { en[cw.cur].ehp: if (cw.now == 1) en[cw.cur].ehp - 10 else en[cw.cur].ehp }
    |> std/store:stored { cw.lasthp: en[cw.cur].ehp }
    |> combat-observe(value: cw.lasthp, fire: cw.now)
    |> std/store:stored { en[cw.cur].ealive: if (cw.now == 1 and en[cw.cur].ehp <= 0) @as(i64, 0) else en[cw.cur].ealive }
    |> std/store:stored { cw.hit: if (cw.now == 1) @as(i64, 1) else cw.hit }
    |> std/store:stored { cw.cur: en[cw.cur].enext }

tor combat-walk { qx: f32, qy: f32 }
combat-walk = for(0..10000, keep: cw.cur != 0 and cw.hit == 0)
    ! each _ |> combat-step(qx, qy)

tor combat-collide {}
combat-collide = std/store:query(pr)
! query p when p.palive == 1 |> std/store:stored { cw.cur: bkt[@as(usize, @intCast(@as(i64, @min(@max(@as(i64, @intFromFloat(@floor(p.ppx / 16.0))), 0), 63)) + @as(i64, @min(@max(@as(i64, @intFromFloat(@floor(p.ppy / 16.0))), 0), 63)) * 64))].head, cw.hit: 0 }
    |> combat-walk(qx: p.ppx, qy: p.ppy)
    |> std/store:stored { p.palive: if (cw.hit == 1) @as(i64, 0) else p.palive }

tor combat-frame {}
combat-frame = combat-move() |> combat-clear() |> combat-rebuild() |> combat-collide()

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
s-fanout = fanout-init() |> for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> fanout-frame()

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

tor s-boids-split {}
s-boids-split = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> boid-frame-split()

tor s-boids-phase {}
s-boids-phase = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> boid-frame-phase()







tor s-boids-fold {}
s-boids-fold = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> boid-frame-fold()

tor s-boids-helpers {}
s-boids-helpers = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> boid-frame-helpers()

tor s-bevy-strength {}
s-bevy-strength = init-dyn() |> init-parts() |> init-orbs()
    |> for(0..@as(usize, @intCast(cfg.frames)))
        ! each _ |> strength-frame()

tor s-churn {}
s-churn = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> churn-frame()

tor s-combat {}
s-combat = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> combat-frame()

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

tor run-boids-split {}
run-boids-split = if(cfg.scenario == 15)
| then |> s-boids-split()
| else |> _

tor run-boids-phase {}
run-boids-phase = if(cfg.scenario == 16)
| then |> s-boids-phase()
| else |> _







tor run-boids-fold {}
run-boids-fold = if(cfg.scenario == 24)
| then |> s-boids-fold()
| else |> _

tor run-boids-helpers {}
run-boids-helpers = if(cfg.scenario == 23)
| then |> s-boids-helpers()
| else |> _

tor run-churn {}
run-churn = if(cfg.scenario == 25)
| then |> s-churn()
| else |> _

tor run-combat {}
run-combat = if(cfg.scenario == 26)
| then |> s-combat()
| else |> _

tor run {}
run = run-dense() |> run-sparse() |> run-query-get() |> run-schedule-empty()
    |> run-spawn() |> run-spawn-batch() |> run-despawn() |> run-add-remove()
    |> run-fanout() |> run-bevy-strength() |> run-boids() |> run-boids-fused() |> run-boids-f2() |> run-boids-f4() |> run-boids-split() |> run-boids-helpers() |> run-boids-fold() |> run-boids-phase() |> run-churn() |> run-combat()

// -------------------------------------------------------------- the checksum
//
// Untimed. `query_get` and `schedule_empty` already carry their own sink, so
// their arms are silent.

// Everything a scenario must build BEFORE the clock starts. Only boids uses
// it; the older rows deliberately keep their construction inside the timed
// region and the README says so.
tor prep {}
prep = prep-boids() |> prep-churn() |> prep-combat()

tor prep-boids {}
prep-boids = if(cfg.scenario >= 11 and cfg.scenario <= 24)
| then |> flock-init() |> flock-normalize()
| else |> _

// The churn world builds AND runs one untimed warmup frame here, then zeroes
// all four counters. The warmup is load-bearing on bevy's side — a
// freshly-inserted component reads as `Changed`, so its frame 0 would fold
// every spawned health into the checksum — and this port has to discard the
// same frame to agree. All four counters are zeroed, not just the checksum,
// which is the asymmetry the bevy harness itself carried until it was fixed.
tor prep-churn {}
prep-churn = if(cfg.scenario == 25)
| then |> churn-init() |> churn-frame()
    |> std/store:stored { ch.csum: 0, ch.trans: 0, ch.dmge: 0, ch.deaths: 0 }
| else |> _

// Enemy and projectile construction is untimed, matching boids and the churn
// world; the frame loop is the measurement.
tor prep-combat {}
prep-combat = if(cfg.scenario == 26)
| then |> combat-init() |> combat-init-pr()
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
fin-boids = if(cfg.scenario >= 11 and cfg.scenario <= 24)
| then |> read-flock()
| else |> _

tor report-phases {}
report-phases = if(cfg.scenario == 16)
| then |> std/io:eprint.ln("koru_store boids_phase actors: {{ ph.pact:d }} ns")
    |> std/io:eprint.ln("koru_store boids_phase clear: {{ ph.pclr:d }} ns")
    |> std/io:eprint.ln("koru_store boids_phase hash: {{ ph.phsh:d }} ns")
    |> std/io:eprint.ln("koru_store boids_phase scatter: {{ ph.psct:d }} ns")
    |> std/io:eprint.ln("koru_store boids_phase resolve: {{ ph.pres:d }} ns")
    |> std/io:eprint.ln("koru_store boids_phase steer: {{ ph.pstg:d }} ns")
| else |> _

// bevy assembles its sink from all four counters, weighted; the archetype
// counts it also prints are diagnostics and are deliberately absent here.
tor fin-churn {}
fin-churn = if(cfg.scenario == 25)
| then |> std/store:stored { acc.sink: ch.csum + ch.trans * 3 + ch.dmge * 5 + ch.deaths * 7 }
| else |> _

tor finish {}
finish = fin-dense() |> fin-sparse() |> fin-spawn() |> fin-spawn-batch()
    |> fin-despawn() |> fin-add-remove() |> fin-boids() |> report-phases()
    |> fin-churn()
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

tor name-boids-split {}
name-boids-split = if(cfg.scenario == 15)
| then |> std/io:print("boids_split")
| else |> _

tor name-boids-fold {}
name-boids-fold = if(cfg.scenario == 24)
| then |> std/io:print("boids_fold")
| else |> _

tor name-boids-helpers {}
name-boids-helpers = if(cfg.scenario == 23)
| then |> std/io:print("boids_helpers")
| else |> _

tor name-boids-phase {}
name-boids-phase = if(cfg.scenario == 16)
| then |> std/io:print("boids_phase")
| else |> _

tor name-churn {}
name-churn = if(cfg.scenario == 25)
| then |> std/io:print("archetype_churn_world")
| else |> _


tor name-combat {}
name-combat = if(cfg.scenario == 26)
| then |> std/io:print("combat_world")
| else |> _






tor emit { ns: i64 }
emit = std/io:print("{\"impl\":\"koru_store\",\"scenario\":\"")
    |> name-dense() |> name-sparse() |> name-query-get() |> name-schedule-empty()
    |> name-spawn() |> name-spawn-batch() |> name-despawn() |> name-add-remove()
    |> name-fanout() |> name-bevy-strength() |> name-boids() |> name-boids-fused() |> name-boids-f2() |> name-boids-f4() |> name-boids-split() |> name-boids-helpers() |> name-boids-fold() |> name-boids-phase() |> name-churn() |> name-combat()
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
