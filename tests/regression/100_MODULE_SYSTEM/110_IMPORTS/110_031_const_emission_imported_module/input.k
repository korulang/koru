// Pins that a flow (flow-implemented tor) in an imported module can
// reference its own module's const block.
//
// Regression 2026-08-20, found by koru-libs/asteroids (sim.thrust-dx
// referencing SHIP_THRUST): the flow body was spliced into the CALLER's
// emitted flow with the const's bare name, but that name only exists inside
// the declaring module's emitted struct — the caller's flow died with
// `use of undeclared identifier 'SCALE'`. A const{} in the ENTRY file always
// landed in the same emitted container as the caller's flows, so no test ever
// covered an imported module's const before (110_028 imports a module but its
// flow references nothing from the module's scope).

import std/io

std/compiler:paths {
    sim: {{ ENTRY }}/test_lib/sim
}

import sim/scaler

sim/scaler:bump (v: 10): t |> std/io:print.ln("bumped: {{ t:d }}")