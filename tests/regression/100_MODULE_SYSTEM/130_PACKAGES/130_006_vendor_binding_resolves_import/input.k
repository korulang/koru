// Pins that a `bindings` block is the ONLY place a vendored tree's path is
// written: the same declaration that pins the bytes also makes the name resolve.
//
// There is no koru.json here. `koru/vaxis` is importable because the block below
// says where it lives, and the import on the next line reads that redirect —
// which is why the block has to act mid-parse rather than at transform time.
//
// The pin still holds: touch a byte under `vendored/` and this becomes 130_004.

import std/io
import std/vendor

std/vendor:bindings {
    koru/vaxis: ./vendored/vaxis
}

import koru/vaxis

koru/vaxis:greet(): v |> std/io:print.ln("{{ v:s }}")
