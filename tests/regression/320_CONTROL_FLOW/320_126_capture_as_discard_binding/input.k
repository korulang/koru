// PIN (2026-07-05, honest red): discarding a capture's `! as` binding with
// `_` breaks Zig emission. The emitter pastes the binding name verbatim as
// the emitted variable name (`var _: __KoruCaptureT__ = ...`), and bare `_`
// is not a declarable Zig identifier, so the user gets a raw host-level
// error (output_emitted.zig: "'_' used as an identifier without @"_"
// syntax") instead of working code or a koru-level diagnostic.
//
// The pit-of-failure kicker: KORU100 (unused binding) HINTS "discard the
// binding using `_` if not needed" — the compiler's own advice walks the
// user into this wall. Surfaced by the textstats kernel port (which needed
// a fold whose `! as` state is only read in a failure arm).
//
// Correct behavior: this compiles and prints 2.
import std/io

capture { n: 1[i64] }
! as _ |> for(0..3)
    ! each _ |> captured { n: 2 }
| captured r |> std/io:print.ln("{{ r.n:d }}")
