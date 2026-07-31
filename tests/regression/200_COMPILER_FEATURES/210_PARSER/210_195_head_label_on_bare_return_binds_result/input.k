// Pins: a NAMED LABEL with a binding on a bare-return tor at the FLOW HEAD is
// binding sugar — `seed() | at p |>` binds p to seed's `-> i64` result, the
// same lowering the NESTED position has always had (810_012 line 23). The
// guarded seam is emitter agreement: the head must emit a direct bind, never a
// field selector on the returned scalar (`result_0.at` — raw Zig about a file
// the author never opened).
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

seed()
| at p |> std/io:print.ln("{{ p:d }}")
