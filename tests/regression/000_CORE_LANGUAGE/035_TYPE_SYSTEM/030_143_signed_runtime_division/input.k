// RED BY DESIGN (pinned 2026-07-25). `/` and `%` on a SIGNED runtime operand
// emit bare Zig `/` and `%`, which Zig rejects:
//
//   error: division with 'i64' and 'comptime_int': signed integers must use
//          @divTrunc, @divFloor, or @divExact
//
// A raw host error, not a koru diagnostic — the wall is not built here yet.
//
// SHOWN 2026-07-25, characterised: signed `/` fails, signed `%` fails, UNSIGNED
// `/` works (usize prints 5), signed `*` works. So it is specific to signed
// division and remainder, not arithmetic generally.
//
// Why it survived: koru's own COMPTIME evaluator already gets this right —
// src/comptime_eval.zig uses @divTrunc/@rem and its comment calls that "the
// C-parity choice". The runtime emitter has no matching lowering, and the
// corpus has zero tests dividing a signed runtime value (everything divides
// literals, which const-fold, or divides usize). Comptime and runtime disagree
// about the same operator.
//
// Found from the outside: building a multi-file ledger app in koru-examples,
// where `cents / 100` compiled while the entry passed a literal and broke the
// moment a second module passed the value through at runtime.
//
// Fix direction (unruled): emit @divTrunc/@rem for signed operands, matching
// comptime_eval's C-parity choice, or reject with a koru-level diagnostic that
// names the operand signedness. Either beats leaking Zig's builtin list.
import std/io

pub tor f { n: i64 } -> i64
f -> n / 2

pub tor go { n: i64 } -> i64
go = f(n): h -> h

go(n: 10): x |> std/io:print.ln("half={{ x:d }}")
