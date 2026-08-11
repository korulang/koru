// Pins that a version-1 lock — one manifest at the top of the entry, written
// before the copied/compiled split existed — still gates a build.
//
// A v1 entry loads as the COMPILED side only. It records what its author last
// accepted and says nothing about what upstream ever held, so `as-copied` stays
// absent rather than being backfilled from it, which would assert a zero-line
// patch nobody verified.

import std/io
import std/vendor

std/vendor:bindings {
    koru/vaxis: ./vendored/vaxis
}

import koru/vaxis

koru/vaxis:greet(): v |> std/io:print.ln("{{ v:s }}")
