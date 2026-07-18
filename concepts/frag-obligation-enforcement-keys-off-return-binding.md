---
type: belief
id: frag-obligation-enforcement-keys-off-return-binding
provenance: surfaced by challenge 005 regression-board triage; fixed by a candidate-fix contest (330_011 cluster restored)
ts: 2026-07-17
---

# Obligation enforcement keys off `return_binding` — so a transform that drops the bind must not drop the obligation (belief)

Every layer of the auto-discharge / phantom machinery mints and checks an
obligation ONLY when the invocation carries a `return_binding`: the inserter's
head-obligation seeding, its continuation-less terminal synthesis, and the
phantom checker's flow-head threading all gate on `return_binding != null`. An
invocation with no bind mints nothing, inserts nothing, and — the dangerous part
— errors nothing. The resource just leaks, silent, at exit 0.

## Why this bit us

The single-return burn-down ([[frag-single-return-form-is-universal]]) ruled that
a consumer fully discarding a bare-return result (`(): _ |> _`) is "just a bare
call" and dropped the dead discard-binds at ~44 sites. Correct as a surface
ruling — but it silently amputated enforcement for the whole unbound-head class,
because enforcement was coupled to the very bind that was removed. The 330 cluster
(011/025/028/036/037/043/070 — MUST_FAIL obligation tests) all went
`must-fail-passed`: the language's phantom-obligation guarantee, its whole reason
to exist, was switched off for these shapes and nobody noticed for ~5 days. (The
first-floated root — a `run-pre-transforms` pass-ordering shift — was WRONG; the
generated dispatch table had zero `.pre`-stage transforms. The coupling to
`return_binding`, not pass order, was the cause.)

## The rule this establishes

- An unbound flow head whose event carries a `return_phantom` must **materialize
  its implicit discard** (`return_binding = "_"`) before enforcement runs, so the
  discard is visible to the machinery identically to the spelled-out `(): _` form
  (the green pin 330_094 is the reference shape). A transform that drops a bind
  MUST preserve the obligation's visibility, or it silently disables the guarantee.
- `--auto-discharge=disable` and `~[strict]` opt out of **inserting** a discharger,
  never out of the discard being **visible** to enforcement. So they run a
  normalize-only pass (materialize + validate, no insertion), not an early-return
  of the untouched AST. Skipping normalization is how an explicit `open(): f` leak
  passed clean under strict/disable — a [[frag-no-fallbacks]] violation in the
  enforcement path itself.
- Declaration validity is independent of insertion mode: KORU083 (`[!]` must be a
  void event) now also fires under disable/strict, and now catches `[!]` on a
  bare-return `-> T` event (single-return moved non-void-ness out of `branches`
  into the return type).

## The record-field frontier is CLOSED (2026-07-18)

An obligation carried as a **record field** (a return/resume record like
`-> { h: *Handle<owned!>, n }`) is now enforced. Two leaks were plugged:
- The emitter used to paste the phantom into the Zig struct type
  (`struct { h: *Handle<owned!>, n }`) — a raw-Zig compile error. It now strips
  the compile-time-only phantom (`*Handle`), the same lift the input side gets for
  free because its parser splits the phantom into `field.phantom`.
- Enforcement keyed off the whole-value `return_phantom` and never descended.
  It now parses the record return type and seeds a per-field obligation
  (keyed `binding.field`, so multiple per record don't collide).

The ruling that settled the *behavior* (Lars: record fields follow the SAME rules
as event-payload fields, which error when undischarged — 690_024): a return-record
field is NOT auto-dischargeable. Unlike a whole-value bare-return obligation
(330_094, auto-discharged) or a branch-payload field (phantom-checker-tracked, so
an inserted disposer type-checks), a return-record field is invisible to the
phantom checker — an auto-inserted `dispose(r.h)` fails validation. So it presents
no disposal candidate and falls to the "was not discharged" wall
(KORU030 "Call: dispose"), guiding manual discharge. Pinned by 330_096.

Full parity (phantom-checker descent into record-return fields, which would make
the field auto-dischargeable) is deliberately NOT built — the pin rules manual
discharge, and the checker-descent is a larger mirror of the input-side tracking.

## Open

Mid-chain unbound obligation calls (`make(): h |> bump(h)` where `bump` returns an
obligation and the chain ends unbound) are the continuation-level twin of this
root — the head-only materialization here does not reach them. Enforcement mints
only when a mid-chain invocation carries a `return_binding`
(`auto_discharge_inserter.zig`), so `bump(h)`'s dropped return leaks. Pinned by
330_097 — still open.
