// The guard side of prototype mode: WITHOUT `[prototype]`, an unhandled
// non-optional terminal is a hard KORU022 error — leniency is granted by the
// annotation alone, never by default. This is byte-for-byte the source of
// 400_160 with the annotation removed: there it compiles and runs; here it
// must be rejected.
//
// This pins that prototype holes cannot leak into ordinary code: no CLI flag,
// no mode, no context grants them — only the greppable in-source annotation.

import std/io

pub tor run {}
| done
| err string

run => err "built path ran; done is still a hole"

run()
| err msg |> std/io:print.ln(msg)
// `| done` unhandled and NO [prototype] — must be KORU022.
