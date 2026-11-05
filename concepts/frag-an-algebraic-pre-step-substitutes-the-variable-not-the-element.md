---
type: belief
id: frag-an-algebraic-pre-step-substitutes-the-variable-not-the-element
provenance: sym B9, 2026-11 — after the dlog lane exhausted
  per-element substitution, the remaining "arg-nonrational" refusals
  (atan(sqrt x), e^{sqrt x}, log(sqrt x)) turned out to need a
  different move entirely: substitute the variable, not an element.
ts: 2026-11-05
tags: [koru, stdlib, sym, risch, integration, substitution, algebraic]
---

# An algebraic pre-step substitutes the variable, not the element

The dlog lane's substitution is per-element: pick a tower leaf θ,
require the integrand to carry θ', transform H into a rational T(t).
That mechanism cannot help when the obstruction is *inside* an
element — atan(√x) has no θ' factor to carry because the problem is
that θ's own argument is not rational. The honest move there is older
and more global: t = √x substitutes the *variable*. Every sq(x) leaf
becomes t, every bare x becomes t², and dx becomes 2t·dt — the whole
integrand rationalizes at once and the inner decider runs on a purely
rational-function tower.

The validity condition is total, not per-element: **every radical
leaf in the integrand must have x for a radicand.** One foreign
radicand — sq(1+x), sq(x²) — leaves an algebraic strand the transform
cannot clear, so the lane refuses `sqrt-subst-mixed-radicand` rather
than partially transform. That all-or-nothing shape is the honest
version of the same discipline the dlog lane learned: a substitution
that reintroduces the obstruction is not a substitution.

Two consequences worth keeping:

* **The lane orders last among the substitution family on purpose.**
  sq-gsub still wins anything carrying the dlog factor (1/(x+√x) →
  2·log(1+√x) is a θ=√x, dlog=1/(2θ) construction), because its
  answers stay in the smaller field — sq-subst's answers spell
  log(√x), e^{√x} where a direct lane would have stayed shallower.
  Ordering matters to output quality, not to correctness: both are
  checked-exact by the same chain-rule argument.
* **checked-exact again needs no post-check.** The transform is a
  node isomorphism, the inner call verifies d/dt res = F(t), and
  d/dx res(√x) = F(√x)·(1/(2√x)) = H(x). The same argument failed to
  hold only once — for rsum answers, whose variable lives inside an
  opaque aux text the node transform cannot reach; the lane names
  `sqrt-subst-rsum` rather than smuggle an unsubstituted x.

The norm side needed one rule to make the family close: u·inv(√u)
fuses to √u — exact field arithmetic (u = √u·√u) with no sign guard,
unlike the sq·sq→u pair-fold which needs a provably nonneg radicand.
Without it, the derivative of x·√x arrives spelled
sq(x) + (1/2)·x·inv(sq(x)) and every downstream coefficient check —
not just this lane's — sees two canons for one element.

What the lane is NOT: it does not integrate √(1+x²) or mixed
radicands — those need Euler substitutions or the real tower, which
remain named refusals. The boundary moved; it did not disappear.
