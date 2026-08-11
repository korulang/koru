// Pins the refusal: when koru.json and a `bindings` block both name `koru/vaxis`
// and point at DIFFERENT trees, the compilation stops.
//
// This is the fault the binding-feeds-the-import work exists to remove. Silently
// preferring either declaration would leave the program importing one tree while
// the pin guards another — a checked dependency that is not the dependency being
// used, which is worse than no pin at all because it reads as protection.

import std/io
import std/vendor

std/vendor:bindings {
    koru/vaxis: ./vendored/vaxis
}

import koru/vaxis

koru/vaxis:greet(): v |> std/io:print.ln("{{ v:s }}")
