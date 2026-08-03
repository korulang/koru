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

tor run {}
run = run-dense() |> run-sparse() |> run-query-get() |> run-schedule-empty()
    |> run-spawn() |> run-spawn-batch() |> run-despawn() |> run-add-remove()
    |> run-fanout() |> run-bevy-strength()

// -------------------------------------------------------------- the checksum
//
// Untimed. `query_get` and `schedule_empty` already carry their own sink, so
// their arms are silent.

tor fin-dense {}
fin-dense = if(cfg.scenario == 1)
| then |> read-all()
| else |> _
tor fin-sparse {}
fin-sparse = if(cfg.scenario == 2)
| then |> read-all()
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

tor finish {}
finish = fin-dense() |> fin-sparse() |> fin-spawn() |> fin-spawn-batch()
    |> fin-despawn() |> fin-add-remove()
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

tor emit { ns: i64 }
emit = std/io:print("{\"impl\":\"koru_store\",\"scenario\":\"")
    |> name-dense() |> name-sparse() |> name-query-get() |> name-schedule-empty()
    |> name-spawn() |> name-spawn-batch() |> name-despawn() |> name-add-remove()
    |> name-fanout() |> name-bevy-strength()
    |> std/io:print.ln("\",\"entities\":{{ cfg.entities:d }},\"frames\":{{ cfg.frames:d }},\"observers\":{{ cfg.observers:d }},\"elapsed_ns\":{{ ns:d }},\"sink\":{{ acc.sink:d }}}")

// -------------------------------------------------------------------- driver

std/args:count(): n |> for(1..n)
! each i |> std/args:get(index: i)
    | arg a |> handle-arg(a)
    | out-of-bounds |> _

if(cfg.scenario == 0)
| then |> std/io:eprint.ln("koru_store: unknown or unimplemented --scenario")
| else |> std/time:now(): t0 |> run() |> std/time:elapsed(start: t0): d |> finish()
    |> emit(ns: @as(i64, @intCast(d.ns)))
