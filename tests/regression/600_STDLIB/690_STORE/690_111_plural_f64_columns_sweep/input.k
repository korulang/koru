// PINS: a CONTAINER whose columns are all f64 — declared, inserted, written
// through the sweep arm's row, and read back.
//
// 690_021 pins f64 on a singleton; 690_049 pins a container with ONE f64
// column beside an i64. An all-f64 container had no pin, and it is the shape
// a numeric consumer declares: an nbody body is seven f64s and nothing else.
//
// The write is an integration step — position advanced by velocity — so the
// pin covers the arithmetic path over typed columns, not just the declaration.
import std/io
import std/store

std/store:new(bodies, capacity: 8) { x: f64, y: f64, vx: f64, vy: f64, mass: f64 }

std/store:insert(bodies) { x: 0.0, y: 0.0, vx: 1.0, vy: 0.0, mass: 10.0 }
std/store:insert(bodies) { x: 1.0, y: 0.0, vx: 0.0, vy: 0.5, mass: 1.0 }
std/store:insert(bodies) { x: 0.0, y: 2.0, vx: -0.5, vy: 0.25, mass: 2.0 }

std/store:query(bodies)
! query b |> std/store:stored { b.x: b.x + b.vx }

std/store:query(bodies)
! query r |> std/io:print.ln("x {{ r.x:f }} y {{ r.y:f }} m {{ r.mass:f }}")
