---
type: belief
id: frag-an-algebraic-pre-step-substitutes-the-variable-not-the-element
provenance: sym B9/B9b/B10/B10c/B10d/B10e, 2026-11 — after the dlog lane exhausted
  per-element substitution, the remaining "arg-nonrational" refusals
  (atan(sqrt x), e^{sqrt x}, log(sqrt x)) turned out to need a
  different move entirely: substitute the variable, not an element.
  B9b added the complementary canon fold the lane's output spelling
  made visible.  B10 added the family's second substitution —
  Euler's first — for the sqrt(x^2+c) radicand the B9 boundary
  paragraph had named as out of reach.  B10c closed the inverse-law
  pair: log(exp u) -> u, the mirror of the exp(log u) -> u fold that
  had been folding silently all along.  B10d paid the conjugate-
  expansion debt B10 itself named — both folds, canon-side.  B10e
  generalized Euler's lane to sqrt(a*x^2+b*x+c) via shift and scale
  pre-steps — and the generalization only held because the norm
  side grew two more mul-fold arms the scale factor required.
ts: 2026-11-05
tags: [koru, stdlib, sym, risch, integration, substitution, algebraic]
---

# An algebraic pre-step substitutes the variable, not the element

The dlog lane's substitution is per-element: pick a tower leaf θ,
require the integrand to carry θ', transform H into a rational T(t).
That mechanism cannot help when the obstruction is *inside* an
element — atan(√x) has no θ' factor to carry because the problem is
that θ's own argument is not rational. The honest move there is older
and more global: substitute the *variable*. The B9 lane uses t = √x:
every sq(x) leaf becomes t, every bare x becomes t², dx becomes
2t·dt. B10's Euler lane uses t = x + √(x²+c): the inverse
x = (t²−c)/(2t) is rational, √(x²+c) spells (t²+c)/(2t), and
dx/dt = (t²+c)/(2t²) — again the whole integrand rationalizes at
once and the inner decider runs on a purely rational-function tower.

The validity condition is total, not per-element, in both members —
but each substitution owns its own radicand predicate. t = √x
requires *every* radical leaf to have radicand x. Euler requires
*every* radical leaf to share one radicand of the exact shape
x² + c (quadratic, leading coefficient 1, no linear term, nonzero
rational constant — c < 0 included, √(x²−1) rationalizes the same
way). One foreign radicand refuses `euler-radicand-mixed`; a shared
radicand of the wrong shape refuses `euler-radicand-shape`; an
x-only radical refuses `sqrt-subst-mixed-radicand`. That
all-or-nothing shape is the honest version of the same discipline
the dlog lane learned: a substitution that reintroduces the
obstruction is not a substitution.

Two consequences worth keeping:

* **The lanes order last among the substitution family on purpose.**
  sq-gsub still wins anything carrying the dlog factor (1/(x+√x) →
  2·log(1+√x) is a θ=√x, dlog=1/(2θ) construction; x·√(1+x²) →
  (1+x²)^{3/2}/3 is θ=√(1+x²), dlog=x/θ), because its answers stay
  in the smaller field. The log family exits the pre-steps' reach
  entirely since B9b: log(sqrt u) -> (1/2)*log u is a canon fold,
  exact on the principal branch (re and im halve — the complex
  case needs no sign guard either), so log(√x) norms to ½log x
  *before any lane sees it* and the primitive cascade answers in
  base field. Ordering still matters for what remains: all lanes
  are checked-exact by the same chain-rule argument.
* **checked-exact again needs no post-check.** The transform is a
  node isomorphism, the inner call verifies d/dt res = F(t), and the
  chain rule closes d/dx res(t(x)) = H(x). The argument fails only
  for rsum answers, whose variable lives inside an opaque aux text
  the node transform cannot reach; the lanes name
  `sqrt-subst-rsum` / `euler-subst-rsum` rather than smuggle an
  unsubstituted variable.

The norm side needed two rules to make the family close. u·inv(√u)
fuses to √u — exact field arithmetic (u = √u·√u) with no sign guard,
unlike the sq·sq→u pair-fold which needs a provably nonneg radicand;
without it, the derivative of x·√x arrives spelled
sq(x) + (1/2)·x·inv(sq(x)) and every downstream coefficient check
sees two canons for one element. The second is the log fold above —
and the honest observation is that *canon gaps masquerade as
capability gaps*: "log(√x) is non-rational" was never a lane
boundary, it was a missing rewrite one level below the lanes.
B10c is the same lesson once removed: the tower probe surfaced
log(e^x)^2/2 as a *correct* but un-folded answer — log(exp u) -> u
had never been written even though exp(log u) -> u folded from the
start. Exactness note: the fold is exact on the real reading (the
complex off-strip case picks up a 2*pi*i winding term) — the same
branch commitment exp(log u) -> u already made, stated rather than
absorbed silently.

B10 adds one more lesson of the same kind, at the level of the
substitution itself: **the parameter choice is the output spelling.**
Euler's first substitution is usually taught as t = √(x²+c) − x,
but its conjugate t = x + √(x²+c) rationalizes identically
(t·conj = c gives the same rational inverse shape) — and norm does
not fold between conjugates, so the two choices emit different
canonical answers for the same integral. Picking t = x + √u makes
the log term spell log(x + √(x²+c)) — the asinh-form textbook
answer — for free.

B10d paid the residual debt — the inv(x+√u) towers — with two
conjugate folds, both exact field arithmetic and neither a
distribution. inv(a+√u) rationalizes to (√u−a)·inv(u−a²), gated on
u−a² norming to a nonzero dec: the fold fires only when the
conjugate product collapses, so no add ever sits under an inv that
wasn't a true conjugate denominator (and inv(3+√11) -> (√11−3)/2
falls out for free, numeric denominators included). The second fold
merges the square pair the first one produces: c·(a+b)² − c·(a−b)²
-> 4·c·a·b, run over the sum's grouped (coeff, base) pairs before
term rebuild — that is what turns Euler's t² and t⁻² terms into
x√u directly, so √(x²±c) emits the textbook x√u/2 ± log(x+√u)/2
rather than any inv-tower. One wrinkle worth keeping: the
conjugate's varying kid carries its own −1 (the canon spelling of
√u−x is add[−x, √u]), so the merged base needs its sign lifted
back into the coefficient — canon-of-negation, not string
equality, is the matching test.

B10e closed the last named boundary item — the general quadratic
√(a·x²+b·x+c) — with pre-steps around the pre-step, each still
variable-substitution machinery: a nonzero linear term shifts
x -> x − b/(2a) (the completing-square move, exact because
shift-back is the same node substitution in reverse), and a leading
coefficient a > 1 scales x -> x·√(1/a) with dx picking up the
√(1/a) coefficient. Both paths re-enter eulerLane at depth+1 on a
now-shaped x²+c radicand; the all-or-nothing discipline is
inherited, not re-implemented.

But the scale path only held because the canon grew again — the
third recurrence of the same lesson. √(1/a) for non-terminating
a (a=3) spells sq(inv(3e0)): its radicand is an inv node, so the
lane's "x-free radicand is an algebraic coefficient" predicate had
to replace the narrower dec-kind test. And inside the scaled
radicand, sq(inv a)·sq(inv a) → inv(a) needed the sq·sq fold's
nonneg predicate extended to inv-of-positive-dec — which then
produced 3·inv(3) in a form the factor-level pair-cancel cannot
see, because dec factors are absorbed into the coefficient *before*
the cancel scans. The third new arm cancels inv-of-dec against the
coefficient directly when the division is exact. Three layers of
the same canon-gap-masquerades-as-capability-gap pattern, this
time all inside the one substitution the coefficient needed. The
block of mul-fold arms the wall forced out of sym.kz now lives in
sym.conj with the other canon merges — the wall's split
coincidentally found the right home.

What the family is NOT: it does not integrate mixed radicands
(√(1+x²)·√(1+2x²) refuses euler-radicand-mixed), negative-leading
quadratics (√(4−x²) is the arcsin class — a real lane, not this
one's pre-step), zero-constant radicands (√(x²), √(4x²+4x+1) =
√((2x+1)²) are absolute-value shapes, non-elementary spellings),
or integrands whose transformed F(t) is non-elementary
(exp(x)·√(1+x²) refuses euler-inner). The boundary moved again;
it did not disappear. True-tower coefficient fields ℚ(x,θ)
remain the named next work.
