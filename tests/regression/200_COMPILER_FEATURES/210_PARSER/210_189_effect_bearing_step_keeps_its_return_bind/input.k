// PINS: a step that declares an effect arm still hands its `-> T` to the name
// bound at the call site. The effect inliner must not drop the bind.
//
// `bump` declares `-> i64` and an `! warn` arm. An event has EITHER `-> T` OR
// terminal branches, never both — but effect arms are a separate kind, so a
// bare-return event may carry them and still produce its value. Here `v` names
// that value and `-> v` produces it.
//
// The bind is written by hand on purpose. When the inliner rewrites an
// effect-bearing call into an inline block it drops the `return_binding`, and
// the name the author wrote reaches Zig as an undeclared identifier — the
// author's own name, in a file they did not open. Writing it out is what
// separates this from the terminus rule: the same shape with the terminus
// SYNTHESIZED (210_184's rule) fails at the identical wall, which is the
// correct behaviour for that rule and the wrong behaviour for the inliner.
//
// Same family as 210_173 and 400_157. 1 + 10 = 11, and `! warn` never fires.
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

tor bump { subject: i64 } -> i64
! warn string
proc bump|zig { return subject + 10; }

tor run {} -> i64
run = seed() |> bump(): v -> v
! warn m |> std/io:print.ln("warn {{ m:s }}")

run(): r |> std/io:print.ln("run = {{ r:d }}")
