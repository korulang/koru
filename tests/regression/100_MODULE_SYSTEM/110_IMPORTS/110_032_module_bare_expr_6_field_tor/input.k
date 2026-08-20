import std/io
// Pins that a module can declare a 6-field bare-expression bool tor.
//
// Regression 2026-08-20, found by koru-libs/asteroids (sim:collide): adding
// a 6-field tor with a bare `<=` bool body to an imported module panicked
// the tap transformer (index-out-of-bounds in transformItems) instead of
// compiling. 4-field tors and record-return tors are fine; the 6-field
// bare-expr bool shape is the trigger.

std/compiler:paths {
    sim: {{ ENTRY }}/test_lib/sim
}

import sim

sim:collide(ax: 0.0, ay: 0.0, ar: 10.0, bx: 18.0, by: 0.0, br: 10.0): hit
|> std/io:print.ln("{{ hit:any }}")
