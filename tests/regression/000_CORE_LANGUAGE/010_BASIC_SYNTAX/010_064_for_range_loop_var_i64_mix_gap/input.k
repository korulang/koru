// RED PIN (2026-07-03): the `for(a..b)` loop variable is emitted as Zig `usize`,
// so NAIVE mixing with i64 arithmetic (`a.acc + i`) is a hard backend compile
// error — and the error that reaches the user is RAW ZIG pointing into
// output_emitted.zig ("incompatible types: 'i64' and 'usize'"), not a Koru
// diagnostic pointing at the .k source line. That leak is why every compute
// kernel carries `@as(i64, @intCast(i))` around its loop var (see the
// koru-benchmarks factorial/digitsum ports).
//
// Sibling of 010_063 (naive `%` on signed i64): same root — .k body-expressions
// are raw Zig strings with no Koru parse-and-lower layer (endeavor "A"). When
// that layer lands, the loop var should participate in the expression's integer
// context (here i64) and THIS TEST GOES GREEN. If instead the ruling is a
// Koru-level diagnostic demanding an explicit widening, this pin flips to
// MUST_FAIL with that diagnostic as expected_error — either way, the raw Zig
// leak is the defect being pinned. See baton_koru_expression_layer_raw_zig_gap.
//
// Semantics check: sum of i over [1,11) = 1+2+...+10 = 55.
import std/io

capture { acc: 0[i64] }
! as a |> for(1..11)
    ! each i |> captured { acc: a.acc + i }
| captured r |> std/io:print.ln("{{ r.acc:d }}")
