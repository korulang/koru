# std/num vs bc — feature matrix, and the SymExpr rung

Tree: `quantity-numbers` @ 3554fb90e + working tree (num/quantity `bad`
ownership fix + qcalc, uncommitted at note time). Measured against GNU bc
1.07.1 (`/usr/bin/bc`) live this session, `plex/lib/std/math.py`,
`plex-agent/three-tier-training.md`, and
`isar-proofs/src/ISAR/QuantityKernel.lean`.

## The race, honestly scored

| surface | bc 1.07 (+ `-l` lib) | koru std/num today | plex math.py | verdict |
|---|---|---|---|---|
| arbitrary precision | decimal, `scale`-bounded | `std.math.big` decimal, per-call `prec` | int + Python float fallback | koru ≥ bc — bc's `scale=0` default makes `1/3 = 0` **silently**; koru takes `prec` explicitly |
| sci notation parse | **none** — `1e3` is a syntax error | canonical `[-]d[.ddd]e[-]E` | float64 parse | koru wins outright |
| `+ − ×` | ✓ | ✓ exact | ✓ | parity |
| `/` | ✓ scale-bound | ✓ prec-gated, `|div-zero` | ✓ | koru ahead — bc's scale is ambient state, koru's prec is an argument |
| `^` | integer only; `2^0.5` → `1` + warning (**silent truncation**) | integer only, `|neg-exp` | int + frac via sqrt/exp | parity — but bc's non-integer path silently degrades; koru's next rung is fractional pow via exp/ln |
| `sqrt` | `-l` only, `scale`-bound | ✓ `prec` argument | Newton | parity-ish — bc honors scale here; koru's prec is still an argument, not ambient state |
| `%` | ✓ | **missing** | — | bc ahead |
| `ibase`/`obase` | 2..16 | **missing** | base_systems (2/8/10/16) | bc ahead; plex had it |
| `s/c/a` trig | `-l` | **missing** | — | bc ahead |
| `l(x)` ln, `e(x)` exp | `-l` | **missing** | exp via Taylor, log TODO | bc ahead |
| `j(n,x)` bessel | `-l` | **missing** | — | bc ahead (niche) |
| `length()`, `scale()` | ✓ | **missing** | — | bc ahead (cheap to add) |
| `++/--`, `+=` etc | ✓ | covered by `add`/`from-int` | — | parity via ops |
| functions/loops | `define`, `for`, `while` | tors + `for`/`if` | — | different strata — bc's are language, koru's are language too |
| dimensions/units | none | 7-base free-abelian + unit table | dims.py | koru only |
| uncertainty/epistemic | none | quadrature + cov terms, `|mixed-cov` refusal | epistemic.py | koru only |
| canonical equivalence | `==` only | `equiv` = NF string-equality | — | koru only |
| taint boundary | none (it IS the boundary) | `external!`→`exact!` linear | — | koru only |

**Net:** bc leads on `%`, bases, and its `-l` transcendental set (s/c/a/l/e/j)
— a thin, closable list. Koru already leads on sci notation (bc can't parse
it), honest precision (bc's two silent degradations would be named refusals
here), and an entire second layer (dims + uncertainty + covariance) bc has
no concept of.

## Speed / memory vs bc (measured, `/usr/bin/time -v`)

| workload | koru | bc | reading |
|---|---|---|---|
| `2^200000` (~60k digits, print) | **6.91 s**, 3.2 MB | **0.22 s**, 2.3 MB | bc ~31× faster. Our `pow` calls `BI.pow` once on the mantissa — the gap is limb-multiplication speed in `std.math.big` vs bc's hand-tuned bignum, not the pipeline. Named, not hidden. |
| `sqrt(2)` @ 1000 digits | ~0.01 s, 3.1 MB | ~0.01 s, 2.1 MB | parity |
| `1/7` @ 2000 digits | ~0.02 s, 3.1 MB | ~0.00 s, 2.1 MB | bc faster but small absolute |

Footprint: ~+1 MB RSS constant (our binary's runtime) vs bc's ~2 MB lean
interpreter. Parity at small precision; a real bigint-speed gap at large
exponents — worth knowing, not worth fixing before the surface is complete
(a faster pow is a `BI` swap or repeated-squaring with truncation policy,
both internal).

## qcalc — a working calculator over this surface

`examples/qcalc/qcalc.k` — stdin lines `<qty> ; <add|sub|mul|div> ; <qty>`,
`std/regex:match` arms for both line grammar and op dispatch. Live output:

    5 m/s ; mul ; 3 s            → 1.5e1|m^1 s^0 ...        (15 m)
    5 m/s ; div ; 2 s            → 2.5e0|m^1 s^-2 ...       (2.5 m/s²)
    4 N ; mul ; 2 m              → 8e0|m^2 s^-2 kg^1 ...    (≡ 8 J)
    2.0+-0.1 m ; add ; 1.0+-0.1 m → 3e0|...|1.41e-1         (quadrature)
    2+-0.1@bias m ; sub ; 1+-0.1@bias m → 1e0|...|-         (bias cancels)
    2+-0.1@a m ; add ; 1+-0.1@b m → mixed-cov               (refusal)
    2 m ; add ; 3 s              → dim-mismatch             (refusal)
    5 kg ; pow ; 3 s             → unknown op: pow          (refusal)

Writing it found a real stdlib leak: `num:parse`'s `|bad` returned the
owned input buffer *before* its free ran, presented as unmarked `string`.
Ruling now landed: **`bad` on parse boundaries carries
`string<std/io:allocated!>`** — ownership transfers to the receiver,
`io:free` disposes, the leak checker can see it. `quantity:lit`'s `bad`
stays an unmarked message (the caller wrote the literal; impl frees the
buffers). Pinned by `615_032_parse_bad_ownership`.

## Missing surface, ranked

1. **Transcendentals** — `exp`, `ln`, `sin`, `cos`, `atan` (bc's `e/l/s/c/a`;
   bessel `j` is niche, skip). All are convergent series + argument
   reduction over the `Dec` core — num-internal logic, honest zig procs
   `num:exp {a, prec}` etc, same shape as `sqrt`. Once `exp`+`ln` exist,
   fractional `pow` follows: `x^y = e^(y·ln x)`, and that unlocks the
   `|non-int-exp` refusal arm as a real branch rather than truncation.
2. **`num:mod`** — remainder; needs integer-division on `Dec` (we have it
   internally for canon normalization).
3. **Bases** — `num:from-int(i, base)` / `parse(s, base)`; plex
   `base_systems` is the port source (2/8/10/16 parse). Small.
4. **Introspection** — `num:length` (digit count), `num:scale` (exp). Cheap.
5. **SymExpr** — the design rung below.
6. **Calculus laws** — derivative/integral/factorization as rewrite data on
   SymExpr (below).

## SymExpr — design

The kernel (`QuantityKernel.lean`) defines it closed:

```lean
SymbolBase = Pi | E | Sqrt(Rational) | Symbolic(String)
SymbolExpr = Rational | Add | Mul | Pow | Symbol
MetricExpr = MetricExact Rational | MetricApprox Float | MetricSymbolic SymbolExpr
```

Quantity in the kernel stacks four lanes: `dim`, `sym`, `mag`, `epis`. Our
pack today is `<mag>|<dim>|<unc>` — the kernel says `mag` itself may BE a
`MetricSymbolic`. So the honest shape is not a new field, it's a wider
`<mag>`: the pack's first field becomes either decimal canon or a
**symbolic canon**.

Symbolic canon sketch: an s-expr-free flat grammar — `π`, `e`, `√(r)`,
`name`, and trees `(<e>+<e>)`, `(<e>*<e>)`, `(<e>^<e>)` — with a normal
form: Add/Mul children canonically ordered (commutative sort by canon
text), rational leaves folded by exact rational arithmetic, `√(4)`→`2`,
`x*1`/`x+0`/`x^1` folded, `x^0`→`1`. Then `equiv` stays string-equality —
the same equivalence law, just a deeper normalizer. Things the NF can't
settle (e.g. `π+e` vs `e+π` — sort handles it; `π²` vs `π*π` — expand-or-
factor choice must be pinned one way) become lawful `|non-canonical`
refusals, never guesses.

Today `lit` folds `π`/`e`/`φ` to digit strings at the boundary — that's the
`MetricApprox` lane and it stays: `lit("π m")` currently → approx. The
SymExpr rung adds `lit-sym` (or a `sym:` param) that issues the same
`<exact!>` mark on a symbolic mag, and arithmetic impls gain a sym lane:
`add` on two symbolic mags produces `Add(...)`, NF'd. Mixed mag×symbolic =
symbolic (exact promotion). `qty:mag` already unwraps to the num tower —
a symbolic mag unwraps to a `std/sym` tower instead, or refuses on
`|symbolic` — the named-axis move.

Uncertainty on symbolic magnitudes: the variance laws are already declared
in Koru — they just need sym-valued sigmas; same mechanics, wider field.

## Derivatives, integrals, factorization — and the "discovery" lineage

The kernel has **no** trig/log/deriv operators — by design the symbolic
layer is four constructors, and everything else is *laws*, not
constructors. That maps cleanly:

- **Derivatives** = a small closed rewrite table on SymExpr
  (d(const)=0, d(x)=1, d(f+g), d(f·g), d(f^n), chain). Declared data,
  total — this is a `sym:deriv` impl, no new kernel.
- **Integrals** = inverse-matching against a known-antiderivative table;
  unresolvable forms refuse `|no-antiderivative` — refusal by default,
  name the axis, exactly the isar-proofs contract.
- **Factorization/decomposition** = another law set (common-factor lift,
  difference of squares); partial by nature → named refusal arms.
- **"Discovery"** — three precedents, only one of which ever ran.
  (a) `compiler_miner` mines rewrite rules out of FASM source corpora —
  rules *from sources*. (b) The dialect-synthesis lane:
  `plex-agent/three-tier-training.md` + `isar-system.py` — Futamura
  projection + confluence clustering (`auto_label_by_confluence`), Tier 2
  rule-ordering, Tier 3 open domains. Real as *design*; the Python calls
  `FutamuraProjection`/`StrategyLearner` which are never defined —
  pseudocode, never run. (c) **The working example — the one that was
  actually remembered**: `isar-proofs/scratch/
  isar_holonomic_closure_algebra.py` (SupGen, session doc
  `docs/holonomic_closure_and_isar_session.md`, runs green 2026-10-31).
  It *discovers* a function's defining law — `derive_holonomic_ode`
  finds a polynomial-coefficient linear ODE for an expression by
  undetermined coefficients over a series residual, solved by exact
  linear algebra and verified residual=0 — then **levels it up**:
  `integral_closure` derives the antiderivative's certificate as the
  algebraic shift of the seed's (∫e^{-x²} → erf-class generator,
  ∫∫ → chain verified against x·erf(x)+e^{-x²}/√π); product/sum
  closure compose generators; composition is *proven impossible in
  general* (Bell-number growth bound — a refusal theorem, not a gap).
  That is "integral from usage": the integral's law derived from the
  integrand's law, not a table. Fib fits the same machinery — a linear
  recurrence is a constant-coefficient holonomic certificate.

  For Koru the translation lands at three depths: numeric transcendentals
  arrived as **series impls over the dec core** (rung 1, landed); the
  deriv/integral/factor tables are declared data first (rung 4); and the
  genuine discovery rung is **SupGen over the sym/Dec tower** — a
  `derive` tor that computes a series expansion at declared precision,
  searches for a polynomial-coefficient linear relation within bounds,
  verifies the residual, and *registers the certificate* — with
  "not found within bounds" as a named refusal (never a non-holonomicity
  claim). `integral` then becomes `integral_closure`-style level-up on
  certificates, and corpus/confluence mining induces rewrite rules as
  data — the compiler-side lane. The TAXONOMY §5.3 e-graph synthesizer
  (I/O-example → program, `extract_best`) stays a third, unrealized
  design lane.

## Proposed order

1. `num:exp`/`ln`/`sin`/`cos`/`atan` (zig series over Dec) → fractional `pow`.
2. `num:mod`, bases, `length`/`scale` — small closers.
3. SymExpr: symbolic `<mag>` lane + NF + `lit-sym`; equiv unchanged.
4. `sym:deriv` table; integral/factor tables with named refusals.
5. Series-from-laws + corpus mining — the actual "discovery" rung.

## Rung 1 landed (2026-10-31)

All six tors shipped in `num.kz` over a fixed-point FX layer (signed bigint
X meaning X*10^-w, width `w = prec + GUARD + max(0, a.e) + 8`, series loops
stop when terms truncate to zero):

- `exp` — Taylor after `e^x = e^k * e^r` split (r folded into [-1/16, 1/16]
  via 4 sqrt-folds of e); `|overflow` when result digits would exceed 10^4.
- `ln` — `ln(f*10^t) = ln(f) + t*ln10`, `ln f = 16*artanh((g-1)/(g+1))` with
  `g = f^(1/16)` via 4 fixed-point sqrts; `|non-pos` for x <= 0.
- `sin`/`cos` — mod-2pi round, fold to [0, pi/2] with sign/flip tracking,
  Taylor. pi via Machin `16*atan(1/5) - 4*atan(1/239)`.
- `atan` — invert to |x|<=1, three argument halvings, Taylor; bare return.
- `powf` — `a^e = exp(e*ln a)`: `|neg-base` for a<0, `a==0 && e<=0` lands on
  `|non-pos`, integral non-negative e takes the exact BI.pow path (so
  `powf(4,2) = 1.6e1` exactly, `powf(4,0.5)` is the inexact `1.9999...`).

Measured correct: `exp(1)` = e to 29 digits; `sin(0.5)`, `atan(0.5)`,
`atan(1)` = pi/4, `powf(2,0.5)` = sqrt(2) — all to printed precision.
Fractional pow is no longer a truncation (bc) or a refusal (prior koru).

Two bugs found by the harness, not by reading: `defer sum.deinit()` on a
*returned* Managed in fxSinSmall/fxCosSmall (dangling limbs -> garbage digits
-> double-free; frag-a-returned-managed-wants-errdefer-never-defer), and the
atan Taylor recurrence missing the `(2n-1)` factor plus sign propagation
through the term (needed unconditional `negate`, not a toggling flag —
x^5/15 instead of x^5/5 and the wrong sign).

Tests: 615_033 (exp/ln + refusal arms), 615_034 (trig), 615_035 (powf +
integral fast path + refusal arms). 615 cluster 27/27, 610 control 19/19,
leak checker on.


## Rung 2 landed (2026-10-31)

`num:mod` (trunc-mod, sign follows dividend, `|div-zero`), `num:length` /
`num:scale` introspection, and integer `to-base`/`from-base` (`|non-int`
for non-integral input, `|bad-digit` on parse) — all over the same Dec
core. Test 615_036; cluster 28/28.

## Rung 3 landed (2026-10-31) — `std/sym`, the symbolic lane

New module `koru_std/sym.kz` with its own mark `<sexpr!>` (module-scoped,
not `num:exact` — boundary stays honest) plus `<sexpr-external!>` for
ingested text that only `parse` discharges.

The canon is a flat grammar: atoms `π e φ`, `√(e)`, `inv(e)`, products
`(e*e)`, sums `(e+e)`, and decimal leaves in num canon. NF rules at build
time: nested add/mul flatten; children sort by canon bytes (coefficient
first in products, constant term first in sums); sum children group by
structural base so `π+π -> (2e0*π)` and `(2e0*π)+(3e0*π) -> (5e0*π)`;
decimals fold (`1/4 -> 2.5e-1` exact); `inv` folds iff the mantissa is a
{2,5}-smooth power (`inv(3)` stays symbolic — no silent inexact); `inv`
distributes over products and `inv(inv(x)) -> x`; `f * inv(f)` cancels;
equal `√` factors pair to their radicand when provably nonneg; `√(dec)`
folds perfect squares including negative exponents (`√(0.25) -> 5e-1`);
negative decimal radicands refuse `|neg-root`; `0` denominators refuse
`|div-zero`. `equiv` is still canon string equality — `e*π` and `π*e`
land on one canon.

Explicit non-goals for this rung: no distributive factoring, no power node
(`π*π` stays a product), no trig/identity tables — those are the
deriv/discovery rungs, not canon mechanics.

Two ownership findings worth keeping: `BI.initSet(0)` allocates default
limb capacity, so "reset the moved slot to a dummy" leaks on the success
path — the fix is borrow-dont-move plus progress-indexed errdefer
(frag-a-dummy-slot-reset-is-an-allocation-in-disguise); and `norm` is
pure (const input, fresh tree) precisely so the error path can hand the
unconsumed input back to the caller for a clean free — a consuming
normalizer makes refusal arms unfreeable.

Tests: 615_037 (canon laws), 615_038 (refusals + taint boundary). 615
cluster 30/30, 610 control 19/19, leak checker on.

Still open in rung 3: the `sym:deriv` table.

## Rung 3b landed (2026-10-31) — symbolic `<mag>` lane in std/quantity

`<mag>` widened to a self-describing field: the pack stays
`mag|dim|unc@cov`, untagged — decimal canon is already a subset of sym
canon (numeric leaves), so `unpack` detects the lane (`magIsDec`) and
produces a `|num|sym` union. Decimal quantities take the identical chain
as before — zero semantic change; sym mags route through `std/sym`; mixed
operands promote via `sym:of-dec` (the bytes already are a numeric leaf,
no re-parse).

New surface: `lit-sym(mag: sexpr!, unit, unc, cov)`, `pack-sym`,
`unit-dim`, `cov-tag`, `mag` now returns the lane union. `sym:of-dec` and
`sym:pow` landed on the sym side; `pow` is repeated-mul NF with negative
exponents through `inv` (`pow(0,-1)` rides `|div-zero`).

Verified live (615_039/615_040): `(π m)+(π m) → (2e0*π) m`;
`π m + 2 m → (2e0+π) m`; `π m * 2 s → (2e0*π) m·s`; `π m / π s →
1e0 m/s`; `-(π m) → (-1e0*π) m`; `(π m)² → (π*π) m²`; mag union routes
`π` to `|sym`. Headline: **`(1/3 m/s) * 3 s → 1e0 m` exactly** — the
decimal lane answers `0.9999…`.

Sigma rule: `add`/`sub`/`neg` carry decimal uncertainty on the sym lane
fully — their sigma math never inspects the magnitude (`(π±0.1@x)+(π±0.1@x)
→ (2π)±0.2@x`). `mul`/`div`/`pow` need `|mag|` for relative sigma, so a
nonzero σ on a sym mag refuses `|sym-unc` by name — the eval rung
(`sym:eval`, MetricApprox) is what would discharge it, and it stays
unbuilt on purpose. Exact sym quantities (σ=0) work through every op.

Two things the rung exposed:

- **`coeff*inv(dec)` was not reduced.** The mul NF folded dec factors
  into the coefficient but `inv(dec)` stayed a factor, so `3*inv(3)`
  printed `(3e0*inv(3e0))`. Fix: reduce `(m_c*10^e_c)/(m_d*10^e_d)` to
  lowest integer terms — den==1 folds into coeff, else the denominator
  rewrites to the reduced canon. This is what makes `4*inv(6e1)` land
  `inv(1.5e1)` — identical to a fresh `1/15` — so equiv = string
  equality stays honest under rational cancellation.
- **Emitter defect, reproduced in 20 lines:** nested union arms sharing
  a name with different payload-ness lose the inner payload capture
  (outer `| same` payload-free → inner `| same g` emits `.same =>` with
  no `|g|`). The workaround is arm renames (`corr`, `bad-unit`,
  `bad-tag`, `bad-lit`); the fix is compiler-core and out of this
  branch's scope. `frag-a-nested-union-arm-name-collision-drops-the-
  payload-capture` has the mechanism and the consumer-side rule.

Tests: 615_039 (sym ops, mixed promotion, exact cancel, mag union),
615_040 (`|sym-unc` refusal on mul/div/pow, sigma still carried on
add). Existing call sites gained the mandatory `|sym-unc` arm; 615_026
exercises the `|num` arm of the new mag union. 615 cluster 32/32, 610
control 19/19, leak checker on.
