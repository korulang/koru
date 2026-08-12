// RED PIN (2026-07-03): the NAIVE Koru `%` operator on signed i64 must compile,
// run, and be C-fast. It currently does NOT: expressions in .k bodies (captured
// fields, if-conditions, args) are passed to Zig as RAW STRINGS, not parsed into a
// Koru AST — so `a % b` reaches Zig verbatim, and Zig REJECTS `%` on signed ints
// ("signed integers and floats must use @rem or @mod"), a hard backend compile
// error. That is why .k authors reach for raw `@mod` (euclidean — and 1.25x slower
// than @rem's truncated remainder, which is C's `%`; measured 45.9ms vs 36.6ms on
// the josephus hot loop).
//
// THE FIX (endeavor "A"): give .k body-expressions a parse-and-lower layer so the
// `%` operator lowers to @rem (truncated, C/Rust semantics) — and `/` to a
// type-aware @divTrunc/`/`. When that lands, THIS TEST GOES GREEN. Until then the
// compute-kernel ports use raw @rem as a faithful stopgap (endeavor "B", shipped).
// See baton_koru_expression_layer_raw_zig_gap.
//
// Semantics check: for i in [2,5): acc=0 -> (0+7)%2=1 -> (1+7)%3=2 -> (2+7)%4=1.
import std/io

capture { acc: 0[i64] }
! as a |> for(2..5)
    ! each i |> captured { acc: (a.acc + 7) % @as(i64, @intCast(i)) }
| captured r |> std/io:print.ln("{{ r.acc:d }}")
