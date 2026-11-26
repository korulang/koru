# exact linear algebra is two engines behind one canon

Measured 2026-11-26 on `rational-kit` (base `a2865cc70`, after
`8f89fe823` std/rational).

The tower's gap was stated as "ℚ arithmetic exists (Rat inside sym),
ℚ linear algebra doesn't (no kit)". `std/linalg` closes it with canon
`mat:v1;<r>;<c>;<n:d>;<n:d>;...` — row-major cells as rational
`numerator:denominator` pairs, the same canon-string-equality law —
and the ruling that landed with it: **exactness is an engine choice
behind one canon, not a property of the canon**.

Two engines, ordered as the inbox note predicted:

- **Bareiss first** — denominator-cleared fraction-free elimination
  over ℤ (the pattern `sym.rsum` proves for ℚ[x] cells, here scalar),
  then honest back-substitution over Rat: each pivot is a nonzero
  leading minor, so division by it is exact. `solve`/`inv`/`det`
  share the tableau; `det` reads the last pivot.
- **Dixon second** (`solve-dixon`) — denom-clear to `Z x = C` over ℤ,
  invert `Z mod p` by Gauss-Jordan over 𝔽_p (Fermat inverse),
  Hensel-lift `x` one p-adic digit per step, Wang-reconstruct each
  entry under bound `isqrt(modk/2)`.

The honest rulings in it:

- **The witness check replaces the Hadamard bound.** Dixon's classic
  stop is a Hadamard bound on `|x|∞`; instead the tor verifies
  `Z·cands == C` *exactly over ℚ* every step — reconstruction runs
  unconstrained-by-bound-estimate, `|open` names only cap exhaustion.
  Sym's propose-and-verify pattern carried to linear solves.
- **`p | det(A)` is `|singular`, not a bug.** A singular mod-p
  matrix refuses Fermat inversion while the ℚ answer exists — pin
  `615_088` shows `solve` returning `x=[2,1]` where `solve-dixon`
  (prime 13, det 13) names `singular`. Prime choice is a param
  *because* refusal is per-prime.
- The engine race is now runnable: same canon, same arms
  (`exact|singular|bad-dims` + dixon's `bad-prime|open`), so
  profiling Bareiss-vs-Dixon is a same-inputs comparison, not a
  port.

Engineering belief corrected en route: `big.int.Managed.init` is
**not free** — it allocates `default_capacity` limbs, so
`var x = Managed.init(a); x = y` leaks the init buffer. The
`var x: BI = undefined; x = expr` spelling is the honest declaration
when a later assignment is certain. (Found by bisect: 1 leak × 3
lift iterations; leak checker counts raw allocs, not bytes.)

Open: `mat` is `string<mat!>` custody only — no collapse admittance
yet (kit-table generalization tracked under the C3 review thread);
`open` has no deterministic trigger in the pin suite (cap exhaustion
needs pathological inputs); `det`'s growth is the profile point
where Dixon is expected to pull ahead.
