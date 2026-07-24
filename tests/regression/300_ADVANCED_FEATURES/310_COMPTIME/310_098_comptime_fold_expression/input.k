// The smallest end-to-end comptime fold: a pure-Koru event evaluated by the
// comptime interpreter at Stage C, its value spliced into the runtime residue.
//
// Grounded surface: the event/impl/bind shape is 020_021 (green) —
// `~pub event double { a: i32 } -> i32`, `~double -> a * 2`, call-site `: d`.
// The `[comptime]` annotation placement mirrors 310_090 (event + flow).
//
// Semantics under test (partial evaluation): the `[comptime]` head invocation
// `answer()` is EVALUATED during backend compilation (the interpreter walks
// the impl `-> 40 + 2`); the flow's continuation is RESIDUE — emitted as
// ordinary runtime code with `r` bound to the folded constant. The binary
// prints 42; nothing about `answer` survives to runtime.
import std/io

[comptime] pub tor answer {} -> i64
answer -> 40 + 2

[comptime] answer(): r |> std/io:print.ln("{{ r:d }}")
