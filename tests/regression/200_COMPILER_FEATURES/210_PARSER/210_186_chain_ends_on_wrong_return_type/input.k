// PINS: a chain whose last step produces the WRONG type does not satisfy the
// flow's `-> T`. Both types are named, in KORU.
//
// The terminus vanishes because the two signatures already agree (210_184).
// When they disagree, the same reading has to say so out loud — a synthesized
// terminus that quietly drops a mismatch would make the flow lie about what it
// returns, and the author would learn it from Zig or not at all.
//
// There is no conversion step and there is no coercion: the last step's return
// type IS the flow's return. `run` declares `i64`, `label` produces a `string`,
// and that is the end of it.
//
// Twin of 210_187 (a chain ending on something that produces nothing at all).
// Both are the negative side of 210_184.
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

tor label { subject: i64 } -> string
proc label|zig { _ = subject; return "x"; }

tor run {} -> i64
run = seed(): a |> label(subject: a)

run(): r |> std/io:print.ln("run = {{ r:d }}")
