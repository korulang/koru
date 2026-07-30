// Pins: a kernel scope owns exactly one view.
//
// A second std/kernel:init nested under another init's | kernel |> branch is
// refused by name. The outer init carries claims_descendants, so the inner one
// never runs as a transform — its dataset would never reach the emitted program
// and its binding would never be substituted, leaving the author's identifier
// to escape into the host as an undeclared name.
//
// Also pins the shape of the refusal: it says what the author was reaching for
// (iteration across two views) and that no kernel op spells it.
import std/kernel
import std/io

std/kernel:shape(Body) {
    mass: f64,
}

std/kernel:init(Body) {
    { mass: 1.0 },
    { mass: 2.0 },
}
| kernel a |> std/kernel:init(Body) {
        { mass: 10.0 },
        { mass: 20.0 },
    }
    | kernel b |> std/kernel:self { b.mass += 1.0 }
    | computed cb |> std/io:print.blk {
            b0={{ cb[0].mass:f }}
        }
| computed ca |> std/io:print.blk {
        a0={{ ca[0].mass:f }}
    }
