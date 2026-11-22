---
type: belief
id: frag-a-sign-factor-wraps-a-subsum
provenance: session 2026-11-14 (Devin) — shifted-Euler conjugate debt: normConjInv stayed
  silent on inv(1/2+x+sqrt u) and normConjSquares missed tbar = -1*(1/2+x)+sqrt u
ts: 2026-11-14
tags: [sym, canon, conjugate, euler, norm-preservation]
related: [frag-parts-are-flat]
---

# A sign factor wraps a sub-sum, not a summand

In canonical add form, `-1*(a+b)` survives as ONE summand — a mul of the
dec -1 and the add — while the same value spelled `-a - b` would land as
two summands. Norm does not distribute the sign over an add; it keeps
the factor. So any test that asks "do these two adds differ only by a
flipped part" cannot match summand-to-summand: the sign may wrap a
whole sub-sum on one side (`t̄ = -1*(1/2+x) + sqrt u`, two kids) while
the twin spells the same block as separate kids (`t = 1/2+x+sqrt u`,
three kids). Measured: `conjSplit`'s kid-pair scan found no conjugate
there because `negCanon(-1*(1/2+x))` is the canon of a *sum* and no
single kid of `t` carries it.

The ruling: pair off canon-identical kids into the shared block first
(multiset intersection); the leftovers on each side must then be exact
negations **as sums** — `canon(norm(-li)) == canon(norm(lj))`. The old
single-summand match is the special case where the sign already sits on
a leaf. Both `shared` and `vary` come back as fresh normed sums.

The same preservation law bit the twin check in `normConjInv`: norm
keeps a summed square `(a+b)^2` factored — squares are the merge target,
expansion would erase what the merge looks for — so `u - a^2` never
surfaces its dec through plain norm. The rationalization test expands
`a^2` pairwise, locally, for the check only; the canonical result keeps
the factored form. Canon preserves forms; a local algebraic check
carries its own expansion.

Open: `t*t̄ = a^2 - u` is a constant when the norm is 1 (`1/(2x+x^2)`:
`inv(t)`'s `t̄` satisfies `t*t̄ = 1`), so `t̄^3*t^2 = t̄` and the cubic
residuals in `615_069`'s last answer would collapse further under a
product-of-conjugates fold. The merge sees squares only today.
