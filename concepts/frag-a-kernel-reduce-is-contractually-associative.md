---
type: belief
id: frag-a-kernel-reduce-is-contractually-associative
provenance: session 2026-08-29 — std/kernel:reduce × `@setFloatMode(.optimized)` (the reduce_kernel benchmark + 390_112 pin)
ts: 2026-08-29
tags: [koru, kernel, reduce, associativity, float-mode, userspace]
---

# A kernel's `reduce` is an associative fold and may reassociate; `self`/`pairwise` may not (belief)

The kernel has a float contract, and it is **per-op**, not per-program. On the one
hand `self` and `pairwise` must stay **strict** — they mutate state, and that state
feeds an oracle that must be reproduced byte-for-byte, so reassociation would be a
rounding change, which is a correctness break (the `kernel.kz` "no FP
reassociation, no oracle change" note is this same ruling). On the other hand
`reduce` is a **fold**: it has no order-dependence by definition, so reassociation
is not a rounding change, it is a legitimate term of the contract. The transform
emits the reduce loop under an optimized float mode and lets LLVM reassociate —
vectorize on changing data, fold on static data — which is exactly what a
`-ffast-math` C build does to the same loop.

The load-bearing point is **scope, not throughput.** C can only unlock this path
with a global `-ffast-math` flag, which you cannot turn on when any of the program
must stay exact. Koru's `reduce` is contractually associative, so the win is
confined to the one op where it is mathematically safe; `self`/`pairwise` stay
strict. That is a parity claim with a reassociating C, not a race — measured on
the reduce_kernel workload, Koru sits at parity with `-ffast-math` C (a hair ahead
on static-data folding, a hair behind on the most adversarial changing data), and
the apparent large speedups only appear next to a strict C that is deliberately
not allowed to reassociate.

The second load-bearing point is **where the change lives**: it is a userspace
library edit (`koru_std/kernel.kz`), not a compiler change. The kernel stdlib is
Koru source the compiler reads at compile time, so the language's *behavior*
moved — the associative contract was added — purely by patching a library. That is
the metacircular claim in action: no `src/` compiler change was needed to give the
language a new semantic.

This is also a correction to a wrong prior in this session: a `self`+`reduce` chain
under `step` was initially diagnosed as dropping the `self` pass (a silent
mis-compile). That was a misread — the emit contains both loops and the compose
works (pinned `390_112_reduce_self_under_step`). No such defect exists.

What would correct this belief: if `reduce` were ever required to reproduce a
strict-scalar result bit-for-bit (then reassociation would be a bug, not a
contract), or if the associative boundary were shown to need compiler-level
enforcement rather than a library rule.
