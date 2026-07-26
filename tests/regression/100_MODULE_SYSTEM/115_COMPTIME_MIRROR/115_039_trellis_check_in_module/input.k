// MIRROR of 680_003_trellis_check_categorize: the trellis definition and its
// `std/trellis:check` dispatch relocated into an imported module, asking its
// question about a kernel flow that stays in the entry file.
//
// Where 115_038 moves a law, this moves a QUESTION whose verdict arrives as
// ordinary branch dispatch resolved at comptime. Same reason for leaving the
// kernel half in the entry: 115_005 already owns kernel's boundary fault.
import std/kernel
import std/io
import app/lib

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

app/lib:verdict()
