// Pins the other half of 130_007: koru.json and a `bindings` block naming the
// SAME tree is agreement, not conflict, and compiles.
//
// The two write the path in different anchors — koru.json's is relative to the
// project root, a binding's to the file declaring it — so the check that refuses
// a disagreement has to compare directories on disk. Comparing the text would
// read these two identical intentions as a contradiction.

import std/io
import std/vendor

std/vendor:bindings {
    koru/vaxis: ./vendored/vaxis
}

import koru/vaxis

koru/vaxis:greet(): v |> std/io:print.ln("{{ v:s }}")
