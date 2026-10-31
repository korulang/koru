---
type: frag
id: a-schoolbook-bigint-caps-exact-op-throughput
provenance: tests/benchmarks/016_num_precision_race (measured 2026-10-31, ReleaseFast, 2000-digit operands)
ts: 2026-10-31
tags: [num, performance, bigint, measurement]
---

Zig's `std.math.big.int.Managed.mul` is schoolbook O(n²). Every exact
`std/num` op (mul, pow, div, mod) and every fixed-point series underneath
`exp`/`ln`/`trig`/`atan`/`powf` rides on it, so at ~2000 digits a
Karatsuba-capable bigint (python `int`/`decimal`) wins exact ops 30–600×
while `bc`'s interpreted Taylor loops lose to koru's compiled ones 2–16×.

The belief: koru's arithmetic *semantics* are verified to the last digit
(full 47713-digit agreement on 3^100000, full 3001-digit agreement on
sqrt(2) vs `math.isqrt`); the *throughput* ceiling is the multiplication
algorithm, not codegen and not Debug-vs-Release (Debug is a further
17–39× slower on top). Any future num-perf work starts at `decMul`'s
limb path — Karatsuba at a limb threshold — not at call sites.

Open: whether a Koru-side Karatsuba belongs in `std/num` or waits for
upstream Zig bigint (std.math.big has open perf issues).
