// MIRROR of 680_001_trellis_enforce_conforming: the trellis DEFINITION and its
// `std/trellis:enforce` law relocated into an imported module, governing a
// kernel flow that stays in the entry file.
//
// The kernel half deliberately does NOT move: kernel:init fails at the boundary
// (115_005), so relocating it too would make this arm red for kernel's reason
// and say nothing about trellis. What moves is the law — a program-wide
// comptime check declared in one module and applied to a flow in another, which
// is the only shape that asks whether a trellis's reach is its own module or
// the whole program.
//
// The module exports a tor the entry calls, so the module is unambiguously live
// rather than an unreferenced import whose law might never be armed.
import std/kernel
import std/io
import app/lib

app/lib:armed()

std/kernel:shape(Body) {
    mass: f64,
}

std/kernel:init(Body) {
    { mass: 1.0 },
    { mass: 2.0 },
}
| kernel k |> std/kernel:self { k.mass *= 2.0 }
| computed c |> std/io:print.blk {
        mass[0]={{ c[0].mass:f }} mass[1]={{ c[1].mass:f }}
    }
