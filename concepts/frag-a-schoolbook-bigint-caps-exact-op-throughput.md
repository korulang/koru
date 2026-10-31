---
type: frag
id: a-schoolbook-bigint-caps-exact-op-throughput
provenance: tests/benchmarks/016_num_precision_race (measured 2026-10-31, ReleaseFast, 2000-digit operands)
ts: 2026-10-31
tags: [num, performance, bigint, measurement]
---

EVOLVED (same day, same rig): the schoolbook ceiling is GONE for
multiplication. `num.kz` now carries its own limb layer — `mulL`
Karatsuba over `[]Limb` with arena scratch, `addL`/`subL`/`addInto`,
routed through `mulFast` at every `Managed.mul` call site, KARA_MIN=24
limbs; `pow10` and `pow` use binary exponentiation (`pow10` was a linear
×10 loop — the silent second cost). Transcendentals dropped 5.6–9.4×;
koru beats bc on 9/10 workloads and beats python-Taylor on ln and powf.

What it cost to learn: `Managed.limbs` is magnitude only — sign lives in
`metadata`/`positive`. A magnitude-multiplying limb path silently
positivizes every product; mantissa-only call sites looked correct while
signed fixed-point (alternating Taylor) broke. Propagate sign at the
Managed boundary, never inside limbs.

Remaining measured ceilings, in order: (1) decimal conversion —
`pow`'s ~315ms on 3^100000 is `toString`+`decFromDigits` round-trip,
not mul; (2) `divTrunc` schoolbook long division (w3/w9 unchanged);
(3) KARA_MIN is a reasoned default, not a swept optimum.
