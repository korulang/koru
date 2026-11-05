---
type: belief
id: frag-a-dlog-factor-is-the-whole-substitution-condition
provenance: sym B7, 2026-11 — the generalized-substitution lane built
  on one condition instead of a per-monomial lattice.
ts: 2026-11-05
tags: [koru, stdlib, sym, risch, integration, substitution, tower]
---

# The dlog factor is the whole substitution condition

For any tower element θ with θ' in the base field, the substitution
t = θ(x) has exactly one validity condition: the integrand must carry
the θ' factor, i.e. H = θ'·T(θ) with T rational. Then ∫H dx = ∫T(t) dt
is a base-field rational integral by construction — no tower-field
machinery, and `checked-exact` is the chain rule over the inner
decider's own check, nothing else.

The older exp-theta lane's affine requirement (g₀ = c₀x + b₀) looked
structural but was only the constant-θ' special case: when θ' = c₀·θ
the factor is invisible inside rational coefficients, so every
rational-in-θ integrand qualifies. For non-affine g the factor is not
invisible — `g'θ/(1+θ)` integrates but `θ/(1+θ)` does not — and the
honest test is whether the x-parts cancel in H/θ', which norm answers
for free: any bare x atom that survives means the substitution
reintroduces x, and the candidate refuses by name.

The same condition unifies the monomial kinds under one lane:
θ = e^g gives dlog = g'·θ, θ = log(u) gives dlog = u'/u — two
spellings of one mechanism. It also explains which families close for
free once the condition is stated: logarithmic derivatives
(g'θ/(a+bθ) → log(a+bθ) for any g), log-power denominators
(1/(x·logᵏx) → t⁻ᵏ for every k), and atan-through-substitution
(quadratic t-denominators ride the Trager machinery in t). What it
does not cover is equally readable from the condition: an integrand
missing the θ' factor, or carrying a second monomial, needs the real
tower — that boundary moved, it did not disappear.

Watch: candidates are enumerated from the integrand's own exp/log
leaves, so an integrand that mixes monomials (e^x·log x) fails every
candidate and refuses — the refusal tag names the last candidate's
failure, which can read narrower than the true reason (mixed tower).
