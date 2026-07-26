import std/kernel
import std/io

std/kernel:shape(Body) { mass: f64 }

std/kernel:init(Body) {
    { mass: 1.0 },
}

pub tor run {}
run = std/io:print.ln("done")
