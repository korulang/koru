---
type: belief
id: frag-store-verb-placement
provenance: ruled by Lars 2026-07-18 during the koru-libs raylib store-as-game-state probe; coverage pinned green as 690_037 after a first diagnosis (scan-context resolution bug) was refuted by the insert-in-body discriminator
ts: 2026-07-18
---

# Stores declare top-level; momentary verbs run anywhere; installations are comptime and top-level-only (belief)

The store declaration (`std/store:new`) names a corpus for the whole
program: top-level. From there the verb surface splits on a comptime/runtime
line that placement rules must follow:

- **Momentary verbs** (insert, take, stored-through-cursor) are runtime acts
  on an existing corpus. They are legal anywhere a body runs — including
  inlined effect-branch bodies. 690_037 pins the nested case green; the
  store registry IS reachable from spliced bodies.
- **Standing-rule installations** (watch, and query-as-standing-rule under
  O13) are comptime-fused — their bodies are copied into write sites (T1).
  At runtime inside an effect body there is nothing to install into, so
  in-body installation is incoherent BY CONSTRUCTION, not by fiat:
  top-level only.
- **stripe on a plural store is unimplemented everywhere** ("later slice"
  per its own diagnostic) — a rung gap independent of placement, and the
  load-bearing one: the O13-coherent per-frame design is standing rules at
  top level + stripe fired inside the frame body.

## The misdiagnosis worth remembering

The probe's query-in-body failure ("unknown store - no std/store:new
found") was first floated as a registry-scan bug. The discriminator
(insert-in-body: works) refuted it. The real defects are (a) a MISLEADING
DIAGNOSTIC — the store exists; the true cause is "installations are
top-level-only" and the message should teach that — and (b) the plural
stripe gap. Diagnosis rule reinforced: before floating a resolution bug,
vary the VERB, not just the placement.

## Enforcement home

The installation-placement law belongs to std/trellis (regex-over-ancestry-
paths placement constraints, Stage-C located diagnostics): trellis is fully
comptime on both halves, so it cannot itself suffer the runtime-install
confusion, and it turns the wall into a declarative teaching message
instead of checker code. Rule sketch: an arm rejecting
`.*!.*/std/store:(watch|query)`-shaped ancestry paths.

## Open

- ~~MUST_FAIL pin for in-body installation (message quality is the point).~~
  DONE 2026-07-23 (690_066): a nested `query` over a DECLARED store no longer
  lies "unknown store - no std/store:new found". The query transform probes for
  the store's persistent coordinator unit (`__store_insert_<s>`, which survives
  after the `new` flow lowers) and, when the store IS declared but this site got
  no sweep unit, teaches the real constraint: "query is top-level-only — a
  standing-rule installation; a nested body has nothing to install into; move it
  to top-level scope. Momentary verbs (insert/take) DO nest." The trellis-law
  ENFORCEMENT home (regex-over-ancestry-paths, Stage-C located) is still the
  aspiration; today's wall lives in the query transform's error path.
- ~~The RETAINED-RENDER read is a SEPARATE momentary verb.~~ LANDED 2026-07-23
  as `std/store:sweep` (690_067). The momentary twin of `query`: "for each live
  row RIGHT NOW, project, run the body." Lowers SITE-LOCAL — schema from the
  persistent `__store_insert_<s>` event (the insert path, survives after `new`
  lowers), body transplanted to a `__store_sweepbody_<s>_L<n>` impl flow, and an
  inline sweep loop emitted AT THE CALL SITE (`.replacement` inline_code +
  `.appended` decls) — NOT a coordinator `__store_qsweep` unit. So it nests
  (proven inside a for-loop body; the vaxis `! draw` case is the point).
  KEY LESSON: a site-local transform that transplants a body carrying `{{ }}`
  template holes MUST be `[claims_descendants]`, or the deeper `print.ln`
  transform resolves the holes depth-first BEFORE the projection binding is in
  scope (pre-transplant), leaving a raw template. `query` dodges this by having
  `create` drive the transplant early on `new`; `sweep` drives its own, so it
  claims its descendants to win the same race. OPEN: top-level `sweep` (outside a
  handler) still hits an inline_code-at-module-scope placement error — a
  follow-up rung; the nested render-bridge case is what works and matters.
- Plural stripe slice: needed before any per-frame system can fire standing
  rules; rule ORDERING under a stripe (move before draw) and the
  cascade-cycle interaction of self-writing movement rules (690_012) are
  unruled design space for the store-as-game-state question.

## Sweep nests structurally; its ROW RESOLUTION does not (2026-07-30)

The claim above — that sweep "nests", proven inside a for-loop body and
against a second store — is true about *placement* and false about *reference*.
Two sweeps can sit one inside the other and each will lower; what does not
survive the nesting is the ability to name the outer row from the inner body.

Measured on a probe with two rows per store, which is the smallest shape that
can tell the two cursors apart at all: the outer binding read inside the inner
body resolves to the INNER store's column at the INNER cursor. Not the wrong
row — the wrong store. No diagnostic. 690_110 pins it.

690_087 is the pin that reads as covering this and does not. Its nested body
touches only the inner binding, and it holds one row per store, so both a
cursor collision and a store misresolution are invisible in it twice over. A
pin whose data cannot distinguish the failure from the success is not evidence,
however precisely it is worded — and this one is worded very precisely, about
`entity` versus bound rows. Binding the row removed the token collision it was
written to remove. It did not introduce a scope, and the belief that it did is
what this section repudiates.

Underneath sit two independent defects, and treating them as one mis-designs
the fix:

- The generated symbols are keyed on the enclosing FLOW's line
  (`__store_sweepbody_<s>_L<n>`). That key is unique only because it was
  inherited from `query`, which is top-level-only, so one query IS one flow.
  Sweep exists in order to nest, and a sweep transplanted into another sweep's
  body carries the parent flow's location — so two sweeps of the same store in
  one flow mint identical symbols. Two sweeps of different stores are pulled
  apart by the store name, which is the second reason 690_087 stayed quiet.
- The row cursor carries a fixed name in every sweepbody event, so an inner
  sweep's cursor shadows the outer's and the column rewrite has nothing left to
  tell the two rows apart.

The key was fixed first, and the reasoning that nearly stopped it is worth
keeping because it was right in general and wrong here. Removing a LOUD wall
without the cursor fix exposes the silent wrong answer beneath it, and a loud
wall traded for a quiet miscomputation is a regression even where a compile
starts succeeding. That rule stands. What it needed was a premise it did not
have: someone able to be misled. The same-store nested sweep does not compile
today, so no program can be relying on the wall, and the measured blast radius
across the store cluster is nil — the identical 16 reds before and after. The
trade is real but it is a trade against nobody, and 690_112 stays red through it
either way, so nothing is laundered by making it red for a different reason.

The general shape: "loud beats silent" is a claim about what a user experiences.
It needs a user. Applied to a surface nothing can reach yet it stops being a
safety argument and becomes a reason not to make progress, which is the failure
mode it exists to prevent in the opposite direction.

This is the store-is-text lesson arriving one level up. The earlier form was a
token rewritten across a subtree with no scope; this form is a rewrite that
correctly distinguishes two BINDINGS and then lowers both onto one cursor. The
binding was made distinct without making the thing it refers to distinct.

## What this costs the numeric reading

An all-f64 container works — declared, inserted, written through the sweep
arm's row, read back (690_111, green, and the first pin of that shape). So the
SoA substrate a numeric consumer wants is real and already emitted. What is not
reachable is the pair: any computation relating two rows of one corpus needs
exactly the cross-row read that 690_110 and 690_112 pin red. Elementwise passes
over a store are available today; pairwise ones are not, and the obstacle is
not layout, iteration or capacity — it is that a row binding does not survive
being nested inside another one.
