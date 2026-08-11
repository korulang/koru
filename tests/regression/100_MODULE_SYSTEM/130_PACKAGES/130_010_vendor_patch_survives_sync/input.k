// Pins the whole point of vendoring: a tree you PATCHED on purpose compiles, and
// the record of what you copied survives the command that accepts the patch.
//
// The lock here was produced by running `vendor sync` over a patched tree, so the
// file itself is the evidence — `as-copied` and `origin` are still present after
// the write that moved `as-compiled`. Before the split, accepting your own fix
// destroyed the only record of what it was a fix TO.
//
// The patch changes the greeting, so the expected output proves the patched
// library is what actually ran — not merely that a patched tree was tolerated.

import std/io
import std/vendor

std/vendor:bindings {
    koru/vaxis: ./vendored/vaxis
}

import koru/vaxis

koru/vaxis:greet(): v |> std/io:print.ln("{{ v:s }}")
