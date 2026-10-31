---
type: frag
id: a-zero-polynomial-has-two-representations
provenance: koru-quantity / sym.certcomp + sym.certgen
ts: 2026-11-01
tags: [koru, zig, poly, ownership]
---

In the sym Poly layer (`[]Rat`, `[]BI`), the zero polynomial has TWO
representations: the empty slice `len == 0` and the slice `[0]`.
`polyEmpty` mints the first; arithmetic like `polyAdd(0, 0)` can mint the
second; `fracsToIntPolys` itself stores `polyEmpty` for a zero Frac.

Every consumer that materializes a *minimum-length* view (`tl = 1` for a
zero poly) and then indexes `p[i]` for `i < tl` reads out of bounds on
the empty representation. Hit twice in one rung: `polyToInts` and the
emit loop of `fracsToIntPolys`, both panicking `index 0, len 0`.

The ruling: normalization predicates (`polyIsZero`, `polyDegIdx`) already
treat both spellings as zero — so an emit/normalize site that computes a
trimmed length must guard `i < p.len` and synthesize a 0 for the
shortfall, never index blindly. Treat `len == 0` as the canonical zero,
`[0]` as an alias the producer may hand you.
