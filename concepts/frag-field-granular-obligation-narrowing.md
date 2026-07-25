---
type: belief
id: frag-field-granular-obligation-narrowing
provenance: introduced by challenge(007) — field-narrowing design walk with Lars
ts: 2026-07-20
---

# A record's obligation-bearing fields discharge independently, narrowing its type down-flow (belief)

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

It is built (landed at `ebbe620f`): a field-projected obligation is a tracked
entity keyed by *path*, and each discharge narrows the source record's type.

Narrowing is position-independent: `330_116` is `330_101` with a void call
prepended and the two agree. Chain position never had any bearing on whether a
field carries a debt — the apparent position-dependence was a missing mirror,
not a design boundary. The flow head seeded record-field obligations; the
intermediate-step path was written for the whole-value case and returned early
whenever a step carried no whole-value phantom, which is exactly what a record
return looks like. Worth remembering as a shape: when a feature works in one
position and not another, look for the second code path that was supposed to
match the first, before concluding the model is positional.

Nested projection (`r.outer.h`) is untracked, one rung further out.

Two questions the feature raises stay open and are Lars's to rule. When two
fields alias one allocation — `.{ .h = h, .g = h }` from a `|zig` body Koru never
reads — each field discharges independently and the binary double-frees; the
phantom model is name-token-based rather than pointer-identity-based by choice,
so this may be an inherent boundary of the chosen model rather than a defect.
What is not in question is that nothing discloses the boundary and no pin probes
it. Separately, whether a discharge diagnostic should name the argument the user
wrote (`s.h`) rather than the parameter it bound to (`x`) is unsettled; `330_109`
pins the neighbouring distinction between "already discharged" and "carries no
obligation."

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
