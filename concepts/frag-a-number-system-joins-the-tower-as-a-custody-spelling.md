# a number system joins the tower as a custody spelling

Measured 2026-11-25 on `rational-kit` (base `a2865cc70`).

The tower's law is not "which numbers exist" but "which numbers can be
*held*". ℚ was computable everywhere and holdable nowhere: `Rat{n,d}`
lived inside sym as a coefficient type, `num:lit "1/3"` returned
`| bad`, and `num:div` took `prec` because Dec division is honest
approximation. What was missing was a custody object, not arithmetic.

`std/rational` closes it as a *spelling*, not a semantics: canon
`rat:v1;<n>;<d>` (d>0, gcd-reduced, zero=`0;1`), value-equivalence as
canon-string equality — the same law `std/num` and `sym.alg` already
state. A new system joins by naming its canon and its custody marks;
arithmetic, comparison, and linearity ops are then the module's own
shape (`dup`/`add`/`mul`/`free`/`cmp`/`equiv`), not negotiated surface.

Rulings that landed with it:

- `lit` accepts `"n/d"`, integers, decimals, and canon — module grammar
  inside `lit { s: string }`, so the kit is strictly additive: no
  parser or syntax surface moves.
- `div` is exact and names `|div-zero`; `dec-of-rat-exact` renders when
  d | 10^k else names `|nonterminating`; `dec-of-rat {prec}` truncates —
  the `num:div` law.
- ℚ↔sym is always exact both ways: `sym-of-rat` emits canon
  (`inv(d)` / `(n*inv(d))` / dec for {2,5} denominators); `rat-of-sym`
  accepts exactly `dec | inv(dec) | (dec*inv(dec))` — the only sexpr
  shapes that name a rational — and refuses the rest on `|bad`.
- `rat-recon` (Wang half-gcd with verified witness) is the Dixon-lift
  recovery kernel — ℚ-linear-solve substrate, in the kit because the
  field is its natural home, not because a consumer exists yet.
- A module names another module's phantom (`string<std/sym:!sexpr>`)
  only under `~import std/sym` — without it every consumer must import
  the phantom's home.

Open: collapse admittance waits on the kit-table `(mod, dup, add,
decode, encode)` generalization in the #21 review thread.
