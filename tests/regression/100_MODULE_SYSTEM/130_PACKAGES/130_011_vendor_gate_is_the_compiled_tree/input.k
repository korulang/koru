// Pins WHICH of the two recorded trees the build is checked against: the compiled
// one, never the copied one.
//
// The tree on disk here hashes to exactly `as-copied` — it is byte-for-byte what
// upstream sent. That is still a refusal, because the program is declared to
// build from the patched tree and someone has reverted it. A gate that accepted
// either side would let a build silently lose a patch it depends on.

import std/io
import std/vendor

std/vendor:bindings {
    koru/vaxis: ./vendored/vaxis
}

import koru/vaxis

koru/vaxis:greet(): v |> std/io:print.ln("{{ v:s }}")
