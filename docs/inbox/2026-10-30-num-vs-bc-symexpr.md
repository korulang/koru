# std/num vs bc — feature matrix, and the SymExpr rung

Tree: `quantity-numbers` @ 3554fb90e. Measured against GNU bc 1.07.1
(`/usr/bin/bc`) live this session, `plex/lib/std/math.py`, and
`isar-proofs/src/ISAR/QuantityKernel.lean`.

## The race, honestly scored

| surface | bc 1.07 (+ `-l` lib) | koru std/num today | plex math.py | verdict |
|---|---|---|---|---|
| arbitrary precision | decimal, `scale`-bounded | `std.math.big` decimal, per-call `prec` | int + Python float fallback | koru ≥ bc — bc's `scale=0` default makes `1/3 = 0` **silently**; koru takes `prec` explicitly |
| sci notation parse | **none** — `1e3` is a syntax error | canonical `[-]d[.ddd]e[-]E` | float64 parse | koru wins outright |
| `+ − ×` | ✓ | ✓ exact | ✓ | parity |
| `/` | ✓ scale-bound | ✓ prec-gated, `|div-zero` | ✓ | koru ahead — bc's scale is ambient state, koru's prec is an argument |
| `^` | integer only; `2^0.5` → `1` + warning (**silent truncation**) | integer only, `|neg-exp` | int + frac via sqrt/exp | parity — but bc's non-integer path silently degrades; koru's next rung is fractional pow via exp/ln |
| `sqrt` | `-l` only, fixed 20 digits | ✓ `prec` argument | Newton | koru ahead on precision control |
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
- **"Discovery"** — the real plex precedent is `compiler_miner`
  (mines rewrite rules out of FASM source corpora) plus math.py's
  series-derived functions (`exp` by Taylor, `sqrt` by Newton — functions
  discovered *from their defining laws*, not from examples). For Koru the
  translation is: numeric transcendentals arrive as **series impls over
  the dec core** (the defining-law lane, already proven in plex), and the
  rule-table lane (deriv/integral/factor tables) is where corpus-mining
  could later feed — mine candidate antiderivatives/identities from the
  test corpus the way compiler_miner mined macros. That's a later rung;
  the tables are declared data first.

## Proposed order

1. `num:exp`/`ln`/`sin`/`cos`/`atan` (zig series over Dec) → fractional `pow`.
2. `num:mod`, bases, `length`/`scale` — small closers.
3. SymExpr: symbolic `<mag>` lane + NF + `lit-sym`; equiv unchanged.
4. `sym:deriv` table; integral/factor tables with named refusals.
5. Series-from-laws + corpus mining — the actual "discovery" rung.
