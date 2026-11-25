---
type: belief
id: frag-collapse-recursion-recognizes-closed-form-accumulators
provenance: WAY-TWO leg of the recursion war — hanoi dossier evidence
  (gcc peel asm showed accumulator jumps collapsing 2^26 toward closed
  form accidentally); design /tmp/waytwo-collapse.md, seat rulings
  auto-fire + __koru_collapse_ marker + fib boundary probe
ts: 2026-11-25
---

# Recurrence-collapse rewrites provable recursive accumulators to closed form (belief)

A `collapse-recursion()` pass at elaborate recognizes pure recursive
accumulator tors — hanoi's sibling-fed `acc` threading (R1), additive and
multiplicative tail accumulators (R2 Faulhaber / square-and-multiply),
fib's two-call produce (B1 fast-doubling), binom's split calls (B2
factorial-quotient) — and rewrites the flow body to a domain-guarded
closed form with checked-op emission and an identity residual that
re-invokes the original event outside the proven region. Auto-fire with
`KORU_COLLAPSE_OFF` opt-out; refusal is silent per gate.

Measured rulings from the implementation leg:

- **The marker must beat flat lowering, twice.** `flowIsFlatEligible`
  requires `inline_body != null`, so setting a collapse body made hanoi
  flat-ELIGIBLE — and the segment lowering re-derived the original
  continuation tree, silently discarding the closed form. The
  `__koru_collapse_` marker check mirrors leg-1's `__koru_unroll_`
  carve-out: `is_flat` reads false, input bindings emit, and BOTH
  self-loop wrapper sites (open AND close) must skip — missing the close
  emitted a stray `}` + `unreachable` at struct level.
- **Kebab names mangle in the residual.** `pow-mod`/`loop-k` events emit
  as `pow_mod_event`/`loop_k_event` (writeMangledSeg `-`→`_`); an
  unmangled residual parses as subtraction (`pow - mod_event`).
- **The i64-exact boundary is a literal, not a wider type.** fib(92) is
  the last i64-exact Fibonacci; doubling computes fib(93) and overflows
  one step early. `if (n == 92) return 7540113804746346429;` sits between
  the n≤91 doubling block and the residual — n≥93 diverges like the
  original's exponential tree.
- **comptime_int ÷ runtime i64 is a backend error.** Domain-guard bound
  checks `k <= STEP_LIMIT / coeff` must emit `@divTrunc`, and emitted
  bodies have no `std` alias — `@import("std").math.*` inline only.

Kernel oracles verified end-to-end: hanoi 33554431, fib(35) 9227465,
powmod 980475159, pascal C(27,13) 20058300, nestedloop 255643180 — all
auto-fired with zero annotations.
