# `[template]` — re-spelling the `|template|` proc-variant (ruling 2026-08-16)

Decision: **narrow.** The live, well-defined template mechanism is the
`|template|` proc-variant, and its spelling is a category error — a
*declaration kind* written in the *variant* slot. Re-spell it as the
`[template]` proc annotation. This is NOT a unification with `[expand]` or
`derive` — those are different mechanisms and stay out of scope.

## Why `|template|` is a category error

The variant bar `|` selects an implementation or build variant of a proc
(`|zig`, `|js`, `|zig(reference)`, `|zig(optimized)`). "This body is a
template" is a *declaration kind*, not an implementation choice. Writing it
as a variant breaks the bar's contract, reads backwards (`|template|zig`:
kind before language), collides with branch-`|` (`| request { … }`), and
carries mode args the bar was never for (`|template(once)|`).

## `template` is NOT `expand` (why this stays narrow)

| | `|template|` proc | `[expand]` event |
|---|---|---|
| Declaration shape | `~proc foo|template|zig { … }` (a proc) | `~[norun|expand]pub tor foo { expr }` (an event slot) |
| Body location | on the proc | in `std/template:define(name:)` registry, matched by name |
| Interpolation | `{{…}}` Liquid, call-site captured args | `${…}` |
| Build-language | `|zig`/`|js` variants | none |
| Status | live, tested (`400_093-095`) | dormant in stdlib (`array.kz` sort, zero calls) but exercised by a test cluster |

Same family (splice a rendered body at a call site); different machines. So
they resolve to different decisions, and only `|template|` gets re-spelled
here.

## After

- `~proc foo|template|zig { … }` → `~[template]proc foo|zig { … }` — the kind
  moves to the bracket; the build variant stays in the bar.
- `|template(once)|` is NOT relocated. Cut it — `template_processor` already
  calls per-decl "probably rare"; add a `[template(once)]` knob only if a
  real need appears.

## What moves (template only)

- `src/template_processor.zig` — `TEMPLATE_TAG`/`ONCE_MODE` variant-name
  matching (1150, 1303, `selectPerCallTemplateProc`) becomes proc-annotation
  matching; the header (1-19) rewritten; `{{…}}` dialect untouched.
- `src/visitor_emitter.zig` — `is_template_variant` (4058) re-derived from the
  annotation instead of the variant name.
- The proc parse path: `[template]` accepted as a proc annotation (the bar
  stays pure variant).
- Tests `400_093-095` (`~proc …|template|…` → `~[template]proc …|…`) and any
  `template(once)` users if present.
- `koru_std/template.kz` doc comment already spells `[template]{…}` — align
  the registry docs to the new proc spelling.

## Explicitly OUT of scope (tracked separately, not bundled)

- **`[expand]`** — a separate event-slot mechanism, dormant in stdlib but used
  by a test cluster (`320_051/052/056/095`, `350_007/009`, `400_184/187`).
  Candidate for deprecation and folding into `|template|` (capability overlaps,
  incl. Expression args — `template_processor.zig:781`), as its own follow-up.
- **`derive`** — orthogonal (generates new declarations from a shape); one test
  (`310_040`); leave alone.
- The `define(name:)` ↔ event name-string coupling, and the `${…}` vs `{{…}}`
  dialect split — separate follow-ups.