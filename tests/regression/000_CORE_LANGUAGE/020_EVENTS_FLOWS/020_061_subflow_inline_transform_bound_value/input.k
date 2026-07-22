// PIN (2026-07-22): an inline-body transform that returns a BOUND VALUE
// (std/fmt:ln → `break :__KORU_INLINE__ .{ .text = … }`) fails to emit when it
// lives inside a SUBFLOW impl. The subflow body-emission path drops the inline
// block in UNLABELED, leaving the `__KORU_INLINE__` placeholder intact, so Zig
// reports `label not found: '__KORU_INLINE__'`. The top-level continuation path
// (continuation_codegen.zig ~273-310) DOES wrap the block in a unique label and
// substitute it — the subflow path must route through the same substitution.
//
// print.ln inside a subflow works (it STREAMS — no bound result, no label), so
// the defect is specific to inline transforms that produce a bound value.
// Sibling of the void-continuation emission-path fix landed earlier the same day.
//
// Expected once fixed: prints `num 42`.
import std/io
import std/fmt

event show { n: i64 }
show = std/fmt:ln("num {{ n:d }}"): l |> std/io:print.ln(l.text)

show(n: 42)
