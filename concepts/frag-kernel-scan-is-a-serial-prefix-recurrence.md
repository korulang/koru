---
type: belief
id: frag-kernel-scan-is-a-serial-prefix-recurrence
provenance: 2026-11-25 — kernelwar scan cell (t72 measured "inexpressible"); arbiter commission made std/kernel:scan real
ts: 2026-11-25
tags: [koru, kernel, scan, prefix-sum, serial, store, float-mode]
---

# A kernel scan is a serial prefix recurrence — state scoped to the op, output is the elements (belief)

`std/kernel:scan` is the prefix-sum op the kernel vocabulary was missing. Its
grammar is `reduce`'s block — `name[type]` entries declare loop-carried
accumulators (zero-init), remaining entries are per-element statements run IN
ORDER — but the semantics differ from every sibling op on three axes:

- **Serial, always.** A prefix recurrence is not row-disjoint, so store mode
  never takes the adaptive parallel path `self` uses; there is no variant tag
  either (`scan|mlir` refuses KORU122 like `reduce`).
- **Strict float.** Unlike `reduce` (contractually associative, runs under
  `.optimized`), scan keeps strict FP — reassociation would break bit-exactness
  against a serial oracle.
- **No exit of its own.** Scan's output IS the mutated elements — `k.<field>`
  writes land on the literal array (`| computed |>`) or the store's SoA column
  (store observable). Accumulator-only bodies are refused KORU123: state with
  no element write is dead compute trapped in the scope.

The accumulator declarations emit ADJACENT to the op's own loop, not hoisted
like reduce's exit-bound accumulators — so a scan under `| step |>` restarts
its recurrence each step. That scoping is the semantic: the state lives exactly
as long as the op's emission region (pre/step/post positions from
frag-a-kernel-chain-sequences-ops-around-step apply unchanged).

Measured 2026-11-25 (Apple Silicon, ReleaseFast, min of 3): 1M-row SoA store
prefix-sum ≈ 952µs/pass vs raw-grid Koru 907µs and C -O2 909.6µs — parity
within ~5%, the store view costing the second grid-cell write the raw arm
needed. Bit-exact vs the Python serial oracle at 1M (chk=-180000.1799958177,
final=-0.24999999999120615).

What would correct this belief: a parallel scan (work-efficient Blelloch)
landing as a `scan|variant` — the serial-only wall exists because no
deterministic parallel lowering exists yet, not because scan is inherently
sequential.

Pin: 390_134 (store), 390_135 (literal+computed), 390_136 (no-write refusal).
