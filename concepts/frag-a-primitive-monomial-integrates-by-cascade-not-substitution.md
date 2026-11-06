---
type: belief
id: frag-a-primitive-monomial-integrates-by-cascade-not-substitution
provenance: sym B6/B8/B10b, 2026-11 — the log lane was expected to
  reuse the exp-theta skeleton; the mechanism turned out different,
  and the difference is the point. The sibling frag's closing
  sentence is corrected here. B8 confirmed 'primitive' is the real
  invariant by lifting the lane to atan(u). B10b found the exact
  check's reach boundary: rsum.
ts: 2026-11-05
tags: [koru, stdlib, sym, risch, integration, log, tower]
---

# A primitive monomial integrates by cascade, not substitution

The exp-theta frag predicted its skeleton — lattice pass, frac
extractor, re-entered decider, substitute back, re-check — would port
to a log monomial. It does not: t = log x gives dx = e^t dt, and the
substitution reintroduces the tower it was meant to remove. For a
*primitive* monomial θ = log(u) (dθ = (u'/u) dx stays in the base
field) the correct mechanism is the coefficient cascade.

An integrand polynomial in θ with base-field coefficients has, when it
has an elementary antiderivative at all, one of the form Σ rⱼ·θ^j with
rⱼ in the same base field — the structure theorem for primitive
extensions, the log analog of Liouville. Matching θ-coefficients in
the derivative yields a descending system
rᵢ' = aᵢ − (i+1)·h·rᵢ₊₁ with h = θ', each step an ordinary base-field
integration that simply re-enters the decider. The mechanism is
kind-blind: θ = log(u) gives h = u'/u and θ = atan(u) gives
u'/(1+u²) — the file renames logmono to primmon because 'primitive'
was always the invariant, 'log' just the first inhabitant. The one
wrinkle a second inhabitant exposed is parity: Trager emits atan(−u)
for the negated root, and atan(−u) = −θ (likewise log(1/u) = −θ), so
leaf matching accepts a parity twin of u with a −1 coefficient —
without it, θ hides inside a coefficient and the cascade assembles a
wrong antiderivative that surfaces only as a check panic. The one genuinely
non-mechanical piece is *limited integration*: rᵢ₊₁ is only known up
to a constant C, which appears in step i's integrand as
−(i+1)·C·u'/u — and that integrates to −(i+1)·C·θ. So the computed
antiderivative's θ-part must be γ·θ with γ constant, and C = γ/(i+1)
closes it. ∫log(x)/x = ½log²x exists precisely because C₂ = ½ is
forced; a θ-part of any other shape (higher powers, x-dependent
coefficients) is the limited-integration failure, and the lane names
it `log-mono-limited` rather than guessing.

Two secondary beliefs fell out of the build and are worth keeping:

* **Coefficients may carry other monomials for free.** log(x+1)
  beside log(x) is just a base-field coefficient of the first lane;
  the cascade recurses on it through the same machinery and the
  whole expression still earns one `checked-exact`. The lane picks
  the first log leaf's argument and never special-cases "mixed" —
  mixed is only a refusal when a coefficient's *inner* integration
  is, and then the refusal is the inner lane's own verdict.
* **The exact check compares field elements, not strings.**
  −x/(x+1) and −1+1/(x+1) canonicalize differently; a string check
  would panic on a true result. Coefficients are compared canon-first
  with a ℚ(x) fallback — the same lesson the exp lane learned as
  "compare Fracs," arrived at from a different side.

The refusal arms point the opposite direction from exp-theta's by
necessity: a log in a non-polynomial position (inv, sqrt, atan, exp —
the rational-in-θ case needs Hermite in the extension, future work), a
non-rational u, degree bounds, depth, and the two honesty arms
`log-mono-inner` / `log-mono-limited`. Latent bugs were found by
the lane rather than by review: the constant-factor split handed a
freed ArrayList buffer to nodeList (any `−1e0·exp(x)·inv(x)` crashed
the decider standalone); the coefficient check was stringly until the
mixed-monomial case produced an equal-but-different-canon coefficient;
and B8's first atan case unmasked a wrong-answer bug upstream —
antiWithConst applied the integrand's constant factor to the rational
part AND to the assembled full text, so every const·(integrand with a
log part) emitted c²·rat + c·log under `checked-exact`. The fix is one
application over (anti0 + ltxt). The hermiteCheck/fracEql verifications
cover the un-consted math only; scaling afterward is exact by
linearity, but the lesson stands: a `checked-exact` tag is only as wide
as the code path it actually verifies.

B10b sharpened that lesson one level up: the check's reach ends at
opaque payloads. When an inner coefficient integral resolves through
Trager's residue-ring lane (atan(1+x^2) -> the quartic x^4+2x^2+2 has
no Q-factorization), the inner call returns a *certified* rsum term —
certified by its own trace-arithmetic check, not by deriveNode. But
the cascade's whole-answer verification re-derives the assembled
antiderivative, and deriveNode treats .rsum as error.Opaque: certified
parts compose into a whole the surface cannot re-verify. The lane
refuses <kind>-mono-inner-rsum rather than emit unchecked — the same
discipline the substitution lanes applied to rsum payloads they could
not transform (gsub-anti-rsum, euler-subst-rsum). The boundary is
verification reach, not capability: the answer x*atan(1+x^2) - rsum
exists and its pieces are each exact-checked; no honesty class in the
decider can carry "assembled from certified parts, unverified as a
whole," and until one exists the refusal is the correct verdict.
