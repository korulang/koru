---
type: belief
id: frag-a-signed-gcd-flips-the-denominator
provenance: the supgen rung printed "1/-8" for -1/8; biGcd on (-1, 8) returned -1 because divTrunc truncates toward zero, and dividing the denominator by it re-inverted the sign
ts: 2026-10-31
---

# A signed gcd flips the denominator (belief)

`divTrunc` truncates toward zero, so a Euclid loop over signed operands can
return a *negative* gcd: `gcd(-1, 8)` walks `x=-1, y=8 -> r=-1`, lands
`g = -1`. Feed that gcd into canonicalization — `num/g, den/g` — and the
sign you just normalized away comes back through the denominator. The
rational `-1/8` printed as `1/-8`: the value was right, the *invariant* the
reader assumed (den > 0) was broken.

The ruling: **any canonicalizing helper that reduces by a gcd must abs()
both operands first.** The gcd is a magnitude — it carries no sign
information downstream. This generalizes the ratNorm discipline: every
normalizer that assumes `den > 0` must enforce it, because the bigint layer
faithfully preserves whatever sign the last division produced.

Adjacent to frag-a-dummy-slot-reset-is-an-allocation-in-disguise: both are
cases where a value that *looks* inert (a zero-fill, a gcd) carries
properties (allocations, sign) the surrounding convention assumed away.
