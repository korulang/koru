# std/rational — the custody ℚ the tower forgot

Tree: `quantity-numbers` @ a2865cc70 (== upstream main). Notes measured
against this tree, this session.

## The gap, stated plainly

The tower computes in ℚ everywhere and holds it nowhere.

- `std/num` Dec is exact **finite decimals ⊊ ℚ**. `num:lit` parses through
  `numParseGate` — `"1/3"` returns `| bad`. `num:div` takes `prec`
  because division on Dec is approximate by contract. There is no
  spelling by which a user holds the value 1/3.
- `Rat{n: BI, d: BI}` — coprime numerator/denominator over the limb Int —
  exists, exactly, as the **coefficient field** inside `sym.supgen.kz`,
  and is what `sym.alg` (ℚ[x]/(p)) and `sym.rsum` (PRS gcd, Bareiss
  inversion) already compute over. It is an implementation type, not a
  custody object: no canon, no phantom, no `dup`/`free`.

So: ℤ (num Int + nt), Dec ⊊ ℚ, algebraic (sym.alg, incl. i = x mod x²+1)
— and the field in the middle, ℚ itself, is internal-only. We forgot
something.

## Proposal: `std/rational` — `string<rational>` custody kit

Same module shape as `std/quantity`: contract-facet `.k` + `.kz`
implementation, phantoms module-scoped, honesty arms named.

### Canon

`"rat:v1;<n>;<d>"` — `<n>` a signed decimal integer, `<d>` a positive
decimal integer, `gcd(|n|, d) = 1`; zero is `0;1` (d=1, positive).
Value-equivalence is string equality on the canon — the same law
`std/num`, `std/quantity`, and `sym.alg` already state. `<n>`/`<d>`
spelling reuses the Dec integer grammar so `nt`/`BI` parsing is shared.

### Custody spellings

Identical discipline to `exact`:

- `string<!rational>` — consume (takes ownership)
- `string<rational!>` — issue (produces owned)
- `string<rational>` — borrow (non-consuming)

### Tor surface

| tor | signature | notes |
|---|---|---|
| `lit` | `{ s: string } \| exact string<rational!> \| bad` | accepts `"n/d"` **and** decimal spellings — every Dec is rational, decimals canonicalize exactly |
| `parse` / `ingest` | external boundary, same as num | `external!` → `rational!` taint discipline |
| `add` `sub` `mul` `div` | `{ a, b: string<!rational> } -> string<rational!>` | `div` adds `\| div-zero` |
| `neg` `abs` | unary, consume → issue | |
| `cmp` `equiv` `is-zero` | borrows | cmp = exact cross-multiply, no approximation |
| `numer` `denom` | `string<rational>` borrow → `string<exact!>` issue | mints Decs — Dec ⊂ ℚ so components re-enter the num kit cleanly |
| `dup` `free` `drop` | custody plumbing | `dup` = the two-owned-copies tor, same contract num's has |
| `from-int` | `{ i: i64 } -> string<rational!>` | `i;1` |
| `render` | `string<!rational>` → `string<allocated!>` | display |
| `rat-of-dec` | `string<!exact>` → `string<rational!>` | exact |
| `dec-of-rat` | `{ a: string<!rational>, prec: i64 } -> string<exact!>` | precision-parameterized — the honesty arm is `prec` itself (same law `num:div` already states) |
| `dec-of-rat-exact` | `string<!rational>` → `exact string<exact!> \| nonterminating` | denominator dividing 10^k renders exactly (`1/4` → `0.25`); otherwise the refusal is named |
| `rat-of-sym` / `sym-of-rat` | canon text bridge | **always exact and lossless** — sym canon already carries decimals and `inv`/division; every rational IS an exact symbolic equation. This is the answer to "what happens to values that can't be finite decimals": they go symbolic, not approximate |

Naming follows the tower's precedent (phantom tag `rational`, canon
prefix `rat:v1`, kebab tor names) — strictly additive surface; the only
open spellings are `"n/d"` inside `lit`'s string argument (module
grammar, not language syntax) and whether `numer`/`denom` mint `exact`
or a leaner int phantom.

Downstream note, not in scope: recognizing a decimal *as* a known
symbol (π, τ, √2) is inverse symbolics — an honest kit names it a
`| candidate` arm, never exact, since a finite decimal can only be
near a constant, not provably equal. A `sym.ident`-shaped module if it
ever earns its place; orthogonal to this kit.

### Engine

Thin canon wrapper over what already exists: `BI` mul/add for
cross-multiplication, `nt-gcd` for reduction on every op. Nothing in
the arithmetic path is new — the module is a custody face on `Rat`,
plus canon parse/format. The `Rat` invariants (`d > 0`, coprime, `0/1`)
are enforced at mint, so ops are closed by construction.

### Composition

- **`sym`**: `sym-of-rat` is exact — the canon already expresses
  `n*inv(d)`/division, so ℚ is a strict subset of what sym expressions
  can say. Values that can't be finite decimals flow to `sym`, not to
  approximation — the tower gains an exact path where `num:div`'s
  prec-contract used to be the only door.
- **`sym.alg`**: `rat` is the deg-0 layer of `alg:v1;<p>;<v>` — the
  coefficient field. A `rat` canon sits naturally below `alg:v1` in the
  same versioned family.
- **`std/quantity`**: quantity packs a Dec magnitude + dim vector — a
  `quantity`-over-rational magnitude is a *new pack*, deferred, not
  blocked.
- **collapse (PR #21)**: the C3 `numacc` family wildcards the phantom
  but matches `callOnPath(…, "std.num", …)` hardcoded. A `std/rational`
  kit is collapse-admittable the moment the matcher takes a
  `(mod, dup, add, decode, encode)` kit table — flagged in #21's review
  thread as the kit-table question. Depends on nothing else in #21.
- **`std/linalg` (future)**: ℚ linear algebra is the real consumer.
  Engine order: **Bareiss first** — fraction-free inversion already
  proven inside `sym.rsum` on this same `Rat` substrate; p-adic/CRT
  lifting (Dixon + rational reconstruction — `nt-extgcd` is already the
  reconstruction kernel) only if profiling shows Bareiss's minor-growth
  as the actual bottleneck. p-adic is an algorithm inside a future
  linalg, not a kit a user spells.

### What this is not

- Not floating point — still none in the arithmetic path.
- Not `std/complex` — complex-of-rationals = ℚ(i), already covered more
  honestly by `sym.alg` (`x mod (x²+1)`); a `complex` phantom over Dec
  pairs would be a strict subset of existing coverage.
- Not a change to `std/num` — Dec stays the approximate-by-contract,
  prec-parameterized decimal; `rat` is the exact peer, not a widening.

## Sized

One module + a 615_NUM pin cluster: `lit`/`add`/`mul`/`div` round-trips
(`1/3 + 1/6 = 1/2` — the thing Dec cannot say), `div-zero`, `bad` on
non-canonical spellings, `dup`/`free` custody under the leak checker,
`dec-of-rat` at prec boundaries, `rat-of-dec` exactness. The
implementation surface is deliberately small — the arithmetic is
already proven; what ships is the custody face.
