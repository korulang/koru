import std/kernel
import std/io

std/kernel:shape(Body) {
    mass: f64,
}

pub tor run {}
run = std/kernel:init(Body) {
    { mass: 1.0 },
    { mass: 2.0 },
    { mass: 3.0 },
}
| kernel k |> std/kernel:step(0..3)
    | step |> std/kernel:self { k.mass += 0.2 }
| computed c |> std/io:print.blk {
        mass[0]={{ c[0].mass:f }} mass[1]={{ c[1].mass:f }} mass[2]={{ c[2].mass:f }}
    }
