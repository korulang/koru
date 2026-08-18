// Pins: a call-site bind on a bare-return tor at the FLOW HEAD (`seed(): p`)
// binds p to seed's `-> i64` result. A sole `| at` continuation is illegal —
// a bare return has no tags. The guarded seam is emitter agreement: the head
// must emit a direct bind, never a field selector on the returned scalar
// (`result_0.at` — raw Zig about a file the author never opened).
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

seed(): p |> std/io:print.ln("{{ p:d }}")
