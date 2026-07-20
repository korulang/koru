---
type: belief
id: frag-field-granular-obligation-narrowing
provenance: introduced by challenge(007) — field-narrowing design walk with Lars
ts: 2026-07-20
---

# A record's obligation-bearing fields discharge independently, narrowing its type down-flow (belief · design, not yet built)

An obligation `<obl!>` is a debt that must be discharged in the scope that holds
it. When a record carries obligation-bearing fields — `{ a: *A<obl!>, b: *B<obl!> }`
— each field's debt is **independent**, and discharging one is field-granular:

- **Discharge consumes.** `dispose(x: s.a)` frees/destroys the resource, so field
  `a` *vanishes* from the record's type — keeping `a: *A` would be a use-after-free,
  the exact thing the obligation system prevents. This is the field-granular form of
  the use-after-discharge rule Koru already enforces on whole values
  (`phantom_semantic_checker.zig:2597`).
- **The record narrows down-flow.** `s: {a!, b!, c!}` → discharge a → `s: {b!, c!}`
  → discharge b → `s: {c!}`. The binding keeps its name; its *type* changes along
  the flow. "The signature of `s` changes down-flow" is not a wart — it is the
  meaning.
- **One field left collapses to a scalar, and the base poisons.** A single-field
  record is illegal in produced positions (`210_149` — "single-entry records
  collapse to the scalar everywhere `->` produces a value"). So when narrowing hits
  one field, the record can't exist: the base binding `s` becomes **poison**
  (invalid as a record) while the surviving projection `s.a` remains valid *as the
  scalar*. No rebind, no rename, no "rest" — `s.a` names the scalar because it is a
  projection; `s` is dead because a `{a}` record is illegal. The only thing you can
  do with `s.a` is project it onto something else (pass it, discharge it).

**Implicit narrowing, never produce-and-rebind.** Discharge must *not* return the
narrowed record for the caller to rebind — that would make `dispose`'s type depend
on which record the field came from, i.e. **color the discharge primitive**. The
narrowing is an implicit effect on the tracked type of the ambient binding; the
discharge event stays a plain `<!obl>` consumer identical to whole-value discharge.

**Destructure needs no rule of its own.** Naming a subset `{ a }` of `{ a!, b! }`
leaves `b` un-bound → `b`'s debt is never discharged → the ordinary discharge rule
fires ("`b` was not discharged"). Omitting an obligation field and naming-it-but-
not-discharging-it are the *same* violation with the *same* message. So "a
destructure must name every obligation field" is not a new check — it falls out of
"every obligation must be discharged." Plain (non-obligation) fields may be dropped
freely; dropping data is not dropping a debt. (Verified: the compiler already
catches the un-named field.)

**Branch/loop:** the same scope discipline as whole-value obligations — arms must
reach the chokepoint with the *same* narrowed signature or the join rejects; a loop
body must be obligation-ledger-invariant.

Spec lives as runnable pins (referenced, not restated): `330_101` (discharge every
field → clean; the positive spec), `330_102` (discharge one, drop → KORU030 on the
remainder), `330_103` (partial destructure omits an obligation → KORU030). The
symptoms that surfaced the whole thing: `330_098` (false-accept under for-each),
`330_100` (diagnostic degrades under subflow).

**Status: design settled, NOT built.** Today the *first* field discharge already
fails — the checker tracks obligations by binding-name string
(`phantom_semantic_checker.zig:2604`) with a fragile `.suffix` fallback, and a
field projection isn't a tracked entity, so `dispose(x: s.a)` reports the
(misleading) "argument carries no obligation here." Building this = making a
field-projected obligation a first-class tracked entity keyed by *path*, and
narrowing the source record's type at each discharge.

**Prior art (why this is distinctive):** pieces exist — Rust's partial moves
narrow what's usable but leaking is *safe* (no must-discharge, `Drop` is automatic
RAII); Move forces you to unpack a resource and account for every field but has no
flow-sensitive field-by-field narrowing; ATS has explicit linear-resource discharge
but no record-narrowing; typestate research langs (Plaid, Mezzo) change a value's
type as you operate but not field-granular obligations collapsing to scalars. The
*combination* — must-discharge debts, field-granular narrowing past Rust's partial
moves, collapse-to-scalar, destructure falling out of the obligation rule, all in a
pipe where the signature visibly narrows — is, as far as we know, not in any one
language. Public claims phrase it "no language *combines* X+Y+Z," never "no language
has any of it."
