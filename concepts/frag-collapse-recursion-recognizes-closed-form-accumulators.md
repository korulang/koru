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

Custody leg (C3 `numacc`, 2026-11-25):

- **The int-scalar event gate is not the pass's boundary.** A second
  eligibility, `custodyEligible`, admits `T { m:int, a:string<!P>,
  b:string<!P> } -> string<P!>` — one signed measure plus two custody
  strings that consume and re-issue the SAME phantom tag. The family
  then re-enters the same guard/branch walk.
- **The dup is custody plumbing; erase it, don't lower it.** The legal
  Koru spelling `dup(b): d |> add(a, d.f1): s |> T(m-1, a: d.f2, b: s)`
  exists only because `add` consumes both operands — the matcher
  requires exactly that orientation (a <- the other dup half, b <- the
  sum), and the emitted body keeps both Dec limbs live natively.
- **Collapse can be a total transform — no residual needed.** Inside the
  guard domain there is no overflow boundary: parse once, run the
  recurrence on limbs, format once. Malformed operands panic with the
  same class `std/num:add` would have raised — equivalence is by
  crash-class, not residual re-entry.
- **The linear loop is the wrong closed form — carry the Q-matrix, not
  the state.** `x_{i+1} = x_i + x_{i-1}` is the Fibonacci matrix, so
  `x_iters = a*f(i-1) + b*f(i)`: fast-double `(f(j), f(j+1))` over the
  bits of the trip count (O(log n) decMul steps), then one linear
  combination of the seeds. Time tracks the VALUE's limb width, not n —
  the same "constant except byte-width steps" shape B1 has at i64.
  Subtraction is emitted inline as neg+add (`decSub` does not exist);
  `BI.clone()` provides the owned neg-copy since Dec copies alias
  limbs. The bit-scan `while` is the one case `for` cannot spell — the
  trip count is a bit-length, unknowable statically (same as B1's own
  emission).
- **Same-file reach.** `koru_std.koru_num.decParse/decAdd/decDeinit/
  decToString/numFree` are file-private fns — reachable from
  `main_module` bodies only because emission is single-file.

Measured on `fibn` carrying `string<!std/num:exact>`: fib(65536) —
uncollapsed 38.5 s ReleaseFast / est. 22 min Debug — runs in **2.9 s
Debug** collapsed (13,696 digits, zero leaks). Every iteration of the
source costs dup + 2 decParse + decToString; the body pays none.
