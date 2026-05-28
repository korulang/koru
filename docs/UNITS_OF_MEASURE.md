# Units of Measure (Dimensional Algebra)

**Status:** Design captured 2026-05-29. Not yet implemented. This document
captures architectural decisions made during the units-of-measure conversation
that produced `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_063..065`
and the syntax cutover from `[label]` to `<label>`.

## The problem

F# units of measure and Frink ship dimensional analysis as a dedicated language
feature: `1.0<m>` cannot be added to `2.0<s>`, `1.0<m> / 2.0<s>` produces
`<m/s>`. Mainstream languages don't have this. It catches the entire class of
"wrong units" bugs at compile time — Mars Climate Orbiter shape.

Koru's phantom system already gives us unit *tagging* at event boundaries
(`f32<celsius>` produced by one event, consumed by another). What it does NOT
yet give us is *dimensional arithmetic* — the rule that when you divide a
`<meter>` value by a `<second>` value, the compiler infers `<meter/second>`
automatically.

This document captures the design for adding dimensional arithmetic as a
**compiler pass alongside the obligation checker**, in the spirit of the
pluggable-semantic-checker architecture documented in
`koru_std/compiler.kz:614` (`~std.compiler:coordinate`).

## Architectural fit

The koru compiler pipeline is a user-overridable event chain. The obligation
checker (`AutoDischargeInserter`, `PhantomSemanticChecker`) runs inside the
`analysis` stage. A units-of-measure checker is **another pass in the same
stage**, alongside the obligation checker.

Both passes look at the same opaque-string labels (`<celsius>`, `<opened!>`,
etc.) but dispatch on different patterns:

- **Obligation checker** activates on labels containing `!`. Resource-cleanup
  semantics. Applies to any base type.
- **Units checker** activates on `!`-free labels attached to **koru-native
  primitive types** (`f32`, `f64`, `i8`–`i64`, `u8`–`u64`). Dimensional
  semantics.

Labels stay opaque to the core compiler. The units checker is the only place
that *parses* a label as an algebraic expression — and that parsing is
contained inside the pass, not exposed to the AST or type system.

Like the obligation checker, the units checker is removable in user-space by
overriding `~std.compiler:coordinate`.

## Scope guard

Dimensional algebra applies ONLY to:
- **Koru-native primitive types**: `f32`, `f64`, `i8`–`i64`, `u8`–`u64`,
  `usize`, `isize`. Bounded, defined set.
- **`!`-free labels** on those primitives. Labels with `!` go to the
  obligation checker; see `TAINT_TRACKING.md` for the obligation-propagation
  story.

Arbitrary Zig types (`*File`, user structs, arrays) get no dimensional
machinery. The phantom on them stays opaque-string-treated by the obligation
checker.

## Composition rules

For two primitive-typed values with labels:

```
a: f32<m>       b: f32<s>
```

Addition / subtraction (units must match):

```
a + b           -> type error: <m> + <s>
a + a           -> f32<m>
a + b<m>        -> type error: cannot mix <m> and <s>
```

Multiplication (units compose):

```
a * b           -> f32<m*s>
a * a           -> f32<m^2>
a * 5.0         -> f32<m>      (untyped scalar coerces; result keeps units)
```

Division (units compose):

```
a / b           -> f32<m/s>
a / a           -> f32<1>      (dimensionless ratio)
a / 5.0         -> f32<m>
```

Comparison (units must match):

```
a < b           -> type error: cannot compare <m> with <s>
a < a           -> bool
a < 5.0         -> ok (scalar) → bool
```

Cast (assertion by author):

```
(a + a)<acres>  -> f32<acres>  (author asserts; compiler trusts)
22.5<celsius>   -> f32<celsius>  (literal origination)
```

## Canonical form

`<m*s^-1>` and `<m/s>` represent the same dimension. The checker normalizes
to a canonical form for comparison. Open design question: what's the canonical
form?

Options under consideration:
- **Multiplicative product form**: `<m*s^-1>` (all factors as products with
  signed exponents). Easier to normalize programmatically. Less natural to
  read.
- **Quotient form**: `<m/s>` (numerator/denominator separated). More natural
  to read. Normalization rules slightly more involved.

Suggested default: quotient form for display, product form internally. The
normalizer canonicalizes both into the same internal representation; pretty-
printing uses quotient form.

## Open design questions

1. **Exponent syntax.** `<m^2>` for square meters? `<m*m>`? Both? F# uses
   `m^2`; SI convention agrees. Probably `<m^2>` as the canonical, with
   `<m*m>` accepted and normalized.
2. **Negative exponents in source.** Should `<m^-1>` be writable directly,
   or only as the result of division? Writable seems fine; restricting
   buys nothing.
3. **Dimensionless `<1>`.** Result of `<m> / <m>`. Should the system treat
   `f32<1>` as equivalent to bare `f32` for assignment/passing? Probably
   yes — otherwise every ratio becomes ergonomically painful.
4. **Mixing primitives.** What happens with `f32<m> + f64<m>`? Same dimension,
   different precision. Probably: type error, author must explicitly convert
   the underlying numeric. The units checker doesn't do numeric coercion.
5. **Author-declared unit aliases.** F# requires `[<Measure>] type m`
   declarations. Koru's opaque-string approach skips this. Consequence: the
   compiler can't tell `<meter>` from `<m>` — different strings, different
   labels. Author must pick one and stick with it. Or: a future feature adds
   an optional declaration mechanism that aliases labels (`unit m = meter`).
   Not blocking — initial implementation can be pure opaque-string and add
   aliasing later.

## Examples

### Velocity from distance and time

```koru
~event read_distance { trip_id: u8 }
| traveled i32<meter>

~event read_time { trip_id: u8 }
| elapsed i32<second>

~event compute_velocity { d: i32<meter>, t: i32<second> }
| result i32<meter/second>

~compute_velocity = result d / t   // body's `d / t` checked as <m>/<s> = <m/s>
```

Verified today by `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_065_phantom_compound_unit`
*at the event boundary* — the producer declares `<meter/second>` and the
arithmetic in the subflow body is trusted. After this design lands, the
body's `d / t` would be *checked* against the declared output: `<meter>` /
`<second>` must produce `<meter/second>`.

### Force, momentum, energy

```koru
~event apply_newtons_second { m: f64<kg>, a: f64<m/s^2> }
| force f64<kg*m/s^2>     // = newtons

~apply_newtons_second = force m * a   // checker validates <kg> * <m/s^2> = <kg*m/s^2>
```

### Reject unit mismatch in arithmetic

```koru
~event try_invalid { a: f64<m>, b: f64<s> }
| result f64<???>

~try_invalid = result a + b   // type error: <m> + <s> rejected
```

## Implementation sketch

1. **New pass: `units_of_measure_checker.zig`** in the analysis stage.
2. **Label parser** (`units_parser.zig`): parses `<m/s^2>`, `<kg*m*s^-2>`,
   etc. into a normalized algebraic representation (map from base-unit name
   to integer exponent). Internal to the pass.
3. **Dispatch logic**: walks the AST, finds binary arithmetic ops where at
   least one operand is a koru-primitive type with a `!`-free phantom label.
   Composes labels per the rules above. Emits error on mismatch.
4. **Subflow body inference**: when `~event = branch <expr>`, the units of
   `<expr>` are computed bottom-up. Compared against the branch's declared
   output label. Mismatch → error.
5. **Cast handling**: `(expr)<label>` syntax. Author asserts the label;
   checker trusts (does not verify expression dimensions match assertion).
6. **Literal origination**: `22.5<celsius>` at call site. Parser captures
   the suffix, strips from emitted Zig (per "no phantoms in Zig-code"
   rule). Checker uses the literal's asserted label.

The implementation is bounded by:
- One new pass (~300–500 LOC for the algebra checker)
- One new label parser (~150–250 LOC, internal to the pass)
- Small parser extension for literal-suffix syntax (`22.5<celsius>`,
  `(expr)<celsius>` cast)

The existing phantom infrastructure (storage, semantic checker for opaque-
string labels, error reporter) handles the rest.

## Why this is the right shape

- **Opacity preserved**: outside the units pass, labels stay opaque strings.
  The AST, the type system, the emitter — none of them learn about units.
- **Composable with obligations**: the obligation checker and units checker
  dispatch on different label shapes (`!` presence). They co-exist on the
  same pipeline without conflict.
- **Removable in user-space**: any user can override `~std.compiler:coordinate`
  and omit the units pass. The language doesn't *require* dimensional algebra;
  it provides it as a default-on convention.
- **Scope-bounded**: only koru-native primitives. Arbitrary Zig types stay
  out of the dimensional system, preventing scope creep.
- **F#-comparable**: the operations and feel match F# units of measure,
  giving Koru parity on the "famous languages have units" axis without
  copying the implementation.

## Related

- `TAINT_TRACKING.md` — the parallel pass for obligation propagation,
  same architectural pattern.
- `COMPILER_ANNOTATIONS.md` — the third bracket-syntax category (`[]` for
  declaration-level metadata, distinct from value-level phantoms).
- `koru_std/compiler.kz:614` — the pluggable compilation pipeline.
- `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_063..065`
  — current units-of-measure tests, boundary-only safety.
- Blog post: `/blog/units-of-measure-for-free` on korulang.org (the public
  framing of the boundary-only story).
