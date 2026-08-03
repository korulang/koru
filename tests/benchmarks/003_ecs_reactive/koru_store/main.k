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
// Store capacity is a compile-time literal, so `bodies` is sized for the
// harness's 100_000 entities. Asking for more is refused loudly rather than
// silently truncated.
import std/io
import std/store
import std/args
import std/string
import std/regex
import std/time

std/store:new(bodies, capacity: 100000) { px: f32, py: f32, vx: f32, vy: f32 }
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

// One frame of `dense`: every body integrates its velocity.
tor integrate {}
integrate = std/store:query(bodies)
! query e |> std/store:stored { e.px: e.px + e.vx, e.py: e.py + e.vy }

tor dense {}
dense = for(0..@as(usize, @intCast(cfg.entities)))
    ! each i |> std/store:insert(bodies) { px: @as(f32, @floatFromInt(i)), py: 0.0, vx: 1.0, vy: -1.0 }
    | done |> for(0..@as(usize, @intCast(cfg.frames)))
        ! each _ |> integrate()

// ----------------------------------------------------------------- the sink
//
// Read back outside the timed region. A whole-store checksum is a stronger
// correctness oracle than the baseline's first-16 tail, and `nanoTimestamp`
// is opaque enough that the read cannot be hoisted across it.

tor checksum {}
checksum = std/store:query(bodies)
! query e |> std/store:stored { acc.sink: acc.sink + @as(i64, @intFromFloat(e.px)) }

// -------------------------------------------------------------------- driver

tor emit { ns: i64 }
emit = if(cfg.scenario == 1)
| then |> std/io:print.ln("{\"impl\":\"koru_store\",\"scenario\":\"dense\",\"entities\":{{ cfg.entities:d }},\"frames\":{{ cfg.frames:d }},\"observers\":{{ cfg.observers:d }},\"elapsed_ns\":{{ ns:d }},\"sink\":{{ acc.sink:d }}}")
| else |> _

tor run {}
run = if(cfg.scenario == 1)
| then |> dense()
| else |> _

std/args:count(): n |> for(1..n)
! each i |> std/args:get(index: i)
    | arg a |> handle-arg(a)
    | out-of-bounds |> _

if(cfg.scenario == 0)
| then |> std/io:eprint.ln("koru_store: unknown or unimplemented --scenario")
| else |> std/time:now(): t0 |> run() |> std/time:elapsed(start: t0): d |> checksum()
    |> emit(ns: @as(i64, @intCast(d.ns)))
