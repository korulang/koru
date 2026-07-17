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

- Author the trellis law + MUST_FAIL pin for in-body installation (message
  quality is the point).
- Plural stripe slice: needed before any per-frame system can fire standing
  rules; rule ORDERING under a stripe (move before draw) and the
  cascade-cycle interaction of self-writing movement rules (690_012) are
  unruled design space for the store-as-game-state question.
