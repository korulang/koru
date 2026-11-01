---
type: belief
id: frag-a-negative-verdict-is-a-proof-only-when-every-case-is-excluded
provenance: decide-ode issued proven-no-liouvillian-solution for y''=(x^2+1)y and y''=(2/x^2)y — both Liouvillian — under a "bounded iff r constant" shortcut; fixed with Kovacic's three necessary conditions on quantity-numbers
ts: 2026-11-01
---

# A negative verdict is a proof only when every case is excluded (belief)

`std/sym:decide-ode` labelled every non-constant `r` "proven" to have no
Liouvillian solution. The label was the error, not the arithmetic: the
shortcut it ran ("bounded iff r constant") is a *sufficient* condition for
the easy positive answer, and its failure says nothing. `y'' = (x²+1)y` has
`e^{x²/2}`; `y'' = (2/x²)y` has `x²`. The refusal arm carried the grade of a
theorem while the code had checked a heuristic.

The ruling: **a "proven-no" arm may fire only when the procedure's whole
case analysis has excluded every case.** Kovacic's algorithm has three cases,
each with necessary conditions on pole orders and the order at infinity.
When all three fail, that is the theorem and the arm says so. When any
survive, the procedure has not decided anything. The arm then names the open
cases (`open-cases=1,3:case-algorithms-not-run`), it does not issue a
verdict. A decision tower's three honest outcomes are *decided-yes*,
*decided-no* and *open, here is what is open*. A fourth outcome that reads
like decided-no but rests on less is a forged certificate.

**Same session, same family: an exact check that shares a constructor with
its subject cannot catch that constructor's bug.** Hermite reduction is
checked exactly (`Q + (B/D⁻)' + C/D* == N/D` over Frac), and the check passed
on a wrong sign. `fracNorm` divided the numerator by a pointer to the
denominator's leading coefficient *after* normalizing that coefficient to 1,
so both the integrand and the result went through the same bad
normalization and still agreed with each other. The sign only showed when the
result went through an independent path (sexpr text → `normCanon`). A
self-consistency check certifies the algebra *relative to the
representation*. Catching a representation bug needs a witness that is
built separately, which is the same rule as the oracle independence in
[[frag-a-phantom-can-only-promise-what-a-producer-can-prove]].

**Same day, the series engine did the same thing.** `series` refused
Catalan's `(1 − √(1−4x))/(2x)` as `non-analytic` because `inv` saw a zero
constant term. The singularity is removable. What the engine actually
checked was "the denominator's first coefficient is zero", which is weaker
than "this function has a pole", and the refusal claimed the stronger one.
Exact Laurent arithmetic fixes the claim: cancellation shrinks the known
prefix instead of inventing zeros, and a pole is reported only when a
negative valuation survives. The real-valued lane draws one more line here:
`√(x²) = |x|` refuses even though `x` squares to `x²`. Choosing that branch
would be a sign guess presented as a series.

Open: the Kovacic case algorithms themselves (which need the poles'
algebraic roots, or a factorization over Q̄) are what turn `open-cases` into
decided-yes with a constructed solution. Until then, an open verdict is the
correct output for those inputs, not a gap that should be papered over.
