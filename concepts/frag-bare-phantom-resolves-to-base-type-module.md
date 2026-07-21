---
type: belief
id: frag-bare-phantom-resolves-to-base-type-module
provenance: ratified phantom-resolution refinement — Lars-ruled 2026-07-21 ("bare state self-resolves to its type's module; primitives self-resolve to here")
ts: 2026-07-21
---

# A bare phantom state self-resolves to its BASE TYPE's module (belief)

Every phantom state is identified by `(declaring-module, name)`. There are no
free-floating states: `celsius`, `secret`, `taken`, `tainted`, `active` are each
really `some/module:name`, and `celsius` in module A and `celsius` in module B
are DIFFERENT states that merely share a spelling.

The resolution rule for the module half of a **bare** phantom (no `mod:`
qualifier):

- **Base type carries a module** (`*app/lib/db:Transaction`) → the bare state
  resolves to the **base type's** module. `*app/lib/db:Transaction<active>` means
  `app/lib/db:active`, regardless of which module writes the annotation.
- **Base type is a primitive** (`string`, `f32`, `u8` — no module of its own) →
  the bare state resolves to the **writing module**, its only available home.
  `f32<celsius>` in module X means `X:celsius`.

An explicitly-qualified state (`<mod:state>`) always names its own module and is
unaffected by this rule.

## Why decoupled-then-self-resolved, not writing-module-always

The prior canonicalization resolved EVERY bare phantom to the writing (event's)
module. That is correct for primitives (they have no other home) but wrong for a
typed base referenced cross-module: `*app/lib/db:Transaction<!active>` written in
module `input` used to canonicalize to `input:active` — a state that can never
match `app/lib/db`'s issued `active`. The type carries its state's home; the bare
form should read it. The change lives in `canonicalizePhantomStateWithBase`
(bare → `base_type_module orelse defining_module`); it touched only bare
resolution, so qualified emissions (e.g. the store's B-narrow columns) are
unaffected. Full-suite diff at the change: 0 green→red.

## Consequences

- **Intrinsic typestate on a module-qualified base gets the bare form
  cross-module for free** — the `*app/db:Transaction<active>` ergonomics.
- **Extrinsic / vocabulary states ride primitives, so they are
  cross-module-by-qualification.** taint, units, `secret` — bare only resolves
  correctly INSIDE the declaring module; every other module MUST qualify
  (`f32<std/units:celsius>`, `string<app/lib/store:!secret>`). A primitive base
  cannot carry the state's home, which is exactly why the qualifier is
  load-bearing, not decoration.
- **There is NO special "reject bare-outside-module" mechanism, and none is
  needed.** A bare foreign state on a primitive self-resolves to a genuinely
  DIFFERENT state and is caught as an ordinary phantom-state mismatch — never
  silently, never via obligation issuer/consumer tracking (Lars: tracking issues
  is out). This is the honest reading of what used to be miscalled a wrong-green.

Pinned by tests (referenced, not restated): `330_087` (qualify a foreign state on
a primitive — required), `330_088` (bare foreign state = distinct-state
mismatch), `330_089` (taint vocabulary qualified cross-module).

## Open — the redundant-qual rejection is UNBUILT

The one-canonical-spelling corollary — a state qualified with the SAME module its
base type already names (`*app/lib/db:Transaction<app/lib/db:active!>`) is
redundant and should be REJECTED with a teaching diagnostic ("drop the
qualifier") — is ratified but not built. `330_112` pins it red. Building it is a
COORDINATED change, not a clean add: the store's B-narrow codegen emits exactly
the redundant form (`*std/string:String<std/string:instance!>`, base and state
both `std/string`), so the store emitter must switch to bare first, AND the
auto-discharge finder must become base-type-aware (it compares canonical strings
verbatim — see [[frag-std-store-design]]), or the rejection breaks B-narrow.
