// PINS: a `-> v` terminus with NO bind and NO chain before it stays refused.
//
// `->` is the produce glyph. `seed() -> v` is the abandoned stray form: one
// call, no `: bind`, an arrow reaching for a value nothing named. The parser
// rejects it and points at the spelling that works.
//
// This is the negative twin of 210_182, and it exists because 210_182's rule
// RELAXES this guard — an arrow is allowed through when a top-level `|>` stands
// before it, because then the arrow belongs to a later step's bind. That
// relaxation is exactly the kind that widens by one more case later with no
// wall noticing, so the shape it must still refuse gets its own pin rather than
// living as a property of the shape that passes.
//
// The discriminator is positional and it is the whole rule: a chain pipe BEFORE
// the arrow makes the arrow a later step's business; no pipe before it makes the
// arrow this line's, and this line has nothing to produce from.
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

tor run {} -> i64
run = seed() -> v

run(): r |> std/io:print.ln("run = {{ r:d }}")
