---
type: belief
id: frag-a-substitution-lane-checks-back-in-the-base-field
provenance: sym B5, 2026-11 — the exp-theta lane needed exactness
  without building the rational-function field over a tower element.
ts: 2026-11-01
tags: [koru, stdlib, sym, risch, integration, exp, tower]
---

# A substitution lane checks back in the base field

An integrand that is a rational function of one monomial θ = e^{g0}
(with g0 affine and every exp leaf an integer multiple of it) reduces
by dt = g0'·t dx to a plain rational integral in t. The tempting frame
is "integrate in the tower field ℚ(x,θ)" — but the lane needs none of
that machinery. The coefficient restriction is what does the work: the
moment x itself must appear inside the integrand's coefficients, the
substitution stops being a field map and the lane honestly refuses.

The exactness story is symmetric to the construction: the
t-antiderivative's derivative, pushed through the same θ-frac
extractor as the integrand, must equal the original F elementwise in
ℚ(t). The check never compares canonical strings — it compares Fracs —
so it is insensitive to how much or little the normalizer folds. A
construction whose check needs a field the lane refuses to build is
not a simplification; the substitution is what lets `checked-exact`
stay cheap.

The boundary is load-bearing, not a limitation to apologize for:
non-affine arguments (e^{x²}), off-lattice constants (e^{x+1} next to
e^x — the lattice test is on a common *root*, because e^{k·b} is not a
rational coefficient), bare-x factors (that is the ℚ(x)-coefficient
lane, a real tower problem), nested exponentials, and rsum leaves in
the t-antiderivative (S(e^{g0},α) has no payload spelling) each name
their own refusal arm. The same skeleton — lattice pass, frac
extractor keyed on the monomial, re-entered decider, node-wise
substitute-back, θ-frac re-check — ports to a log-monomial lane; what
changes is which direction the refusal arms point.
