// PINS: a WIDE all-f64 container — one entity row carrying four flattened ECS
// components (Transform mat4x4 as 16 columns, Position/Rotation/Velocity vec3
// as 9) — declared, inserted twice, swept back, with the declaration and the
// insert literal both spanning MULTIPLE LINES.
//
// This is ecs_bench_suite's simple_insert row (rust-gamedev's workload, not
// ours) in the only spelling the column system has: pure SoA scalars, one
// column per lane. Compound column TYPES (a vec3/mat4x4-valued column) remain
// uninvented surface — 690_020 carries that residue. Until they exist, this is
// the spelling a game consumer writes, and the corpus's widest store before it
// was seven columns (690_111); a 25-column store, and a `new`/`insert` block
// broken across lines, had never been asked for.
import std/io
import std/store

std/store:new(ents, capacity: 4) {
    t00: f64, t01: f64, t02: f64, t03: f64,
    t10: f64, t11: f64, t12: f64, t13: f64,
    t20: f64, t21: f64, t22: f64, t23: f64,
    t30: f64, t31: f64, t32: f64, t33: f64,
    px: f64, py: f64, pz: f64,
    rx: f64, ry: f64, rz: f64,
    vx: f64, vy: f64, vz: f64
}

std/store:insert(ents) {
    t00: 1.0, t01: 0.0, t02: 0.0, t03: 0.0,
    t10: 0.0, t11: 1.0, t12: 0.0, t13: 0.0,
    t20: 0.0, t21: 0.0, t22: 1.0, t23: 0.0,
    t30: 0.0, t31: 0.0, t32: 0.0, t33: 1.0,
    px: 1.0, py: 2.0, pz: 3.0,
    rx: 0.0, ry: 0.0, rz: 0.0,
    vx: 0.5, vy: 0.25, vz: 0.125
}

std/store:insert(ents) {
    t00: 2.0, t01: 0.0, t02: 0.0, t03: 0.0,
    t10: 0.0, t11: 2.0, t12: 0.0, t13: 0.0,
    t20: 0.0, t21: 0.0, t22: 2.0, t23: 0.0,
    t30: 0.0, t31: 0.0, t32: 0.0, t33: 4.0,
    px: 10.0, py: 20.0, pz: 30.0,
    rx: 0.0, ry: 0.0, rz: 1.5,
    vx: 5.0, vy: 2.5, vz: 1.25
}

std/store:query(ents)
! query e |> std/io:print.ln("t00 {{ e.t00:f }} t33 {{ e.t33:f }} px {{ e.px:f }} rz {{ e.rz:f }} vz {{ e.vz:f }}")
