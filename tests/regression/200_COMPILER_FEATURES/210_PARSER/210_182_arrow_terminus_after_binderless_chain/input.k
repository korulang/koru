// PINS: a `-> v` terminus is legal when the bind that feeds it sits on a LATER
// step of the chain, not on the head.
//
// `->` is the produce glyph and a bare `event() -> v` is the abandoned stray
// form, so the parser refuses an arrow with no bind before it. The bind it
// looked for was the HEAD call's, found by scanning just past the head's `)` —
// which is the whole of a one-call line and none of a chain. Once the steps
// between the head and the terminus stop needing binders (the thread carries
// the value now — 210_176), the only bind left is on the LAST step, and the
// head has none. The shape below was refused for that reason alone.
//
// The arrow here belongs to `bump(): c`, and a `|>` stands before it. That is
// the tell: an arrow with a chain pipe in front of it is a later step's
// business, parsed with that step.
//
// This is the shape `koru_std/compiler.kz`'s `~elaborate` collapses to — six
// stages, no intermediate binders, one `-> c4` terminus. 1 + 10 + 10 = 21.
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

tor bump { subject: i64 } -> i64
proc bump|zig { return subject + 10; }

tor run {} -> i64
run = seed() |> bump() |> bump(): c -> c

run(): r |> std/io:print.ln("run = {{ r:d }}")
