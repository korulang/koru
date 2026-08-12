// PINS: a chain that BOTH threads by type AND needs its terminus synthesized.
// Zero binders, start to finish.
//
// The two rules are pinned separately and neither pin exercises the other.
// 210_176 and 210_175 thread a value mid-chain, and both END on a step whose
// value nothing needs. 210_184 synthesizes the terminus, and it writes every
// argument explicitly so nothing threads. The product of the two — a chain
// where the thread carries the value AND the last step's return is the flow's
// return — had exactly one instance anywhere, `elaborate` in
// `koru_std/compiler.kz`, and no test at all.
//
// That gap is the whole reason this file exists. A shape whose only instance is
// the compiler's own pipeline is a shape you find out about by breaking the
// compiler, and then you are debugging two things at once: whether the rule is
// wrong, and whether the tree you measured was the tree you thought.
//
// This is `elaborate` in miniature. Each stage takes an `i64` and returns one,
// so every `bump()` has its parameter filled by the thread, and `run`'s `-> i64`
// is satisfied by the last `bump` without a terminus being written.
// 1 + 10 + 10 = 21.
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

tor bump { subject: i64 } -> i64
proc bump|zig { return subject + 10; }

tor run {} -> i64
run = seed() |> bump() |> bump()

run(): r |> std/io:print.ln("run = {{ r:d }}")
