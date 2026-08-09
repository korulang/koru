// Pins that a `build:variants` key for a SUBMODULE event actually selects.
//
// The key is written the way the program IMPORTS the module — `mylib/pump:run`
// — while the call site is canonicalized to the module's LOGICAL name,
// `mylib.pump:run`. An exact string compare never matched, so the registration
// parsed, `configured` fired, and every call site quietly kept the default
// handler. Selecting a variant on a submodule could not work at all.
//
// It hid because a TOP-LEVEL event has no separator to disagree about
// (`"input:pump"` is spelled identically on both sides), and every variant test
// in the suite used one. Orisha's own `~[build(linux)]` line, selecting its
// epoll pump, had never taken effect either.

import std/io
import std/build
import mylib/pump

std/build:variants {
    "mylib/pump:run": "alt"
}
| configured _ |> _
| skipped _ |> _
| invalid-event _ |> _

mylib/pump:run(n: 1): r |> std/io:print.ln(r)
