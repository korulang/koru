---
type: belief
id: frag-tap-observes-a-transition
provenance: surfaced stepping back on the tap library after the 320/322 tap-subflow double-emit was localized to the weaver (spliceContinuations grafting under a bare RETURN) via the KORU_DUMP_AST post-transform tree render (2026-07-15)
ts: 2026-07-15
---

# A tap observes a transition; a terminus is the degenerate case (belief)

A tap is **an observation spliced at a production point** — the instant a tor
produces a value. The whole mental model is a thing wedged *into* a flow: the
tor produces, the tap fires, and then the flow carries on past it. That model
silently assumes there is an **"after"** to carry on into.

There are exactly two shapes, and they are the same idea told at two positions:

- **Mid-flow tap** — the tapped tor has a downstream. `produce → observe →
  continue`. The observation is inserted before the downstream and the flow
  proceeds. This is the case the weaver was built around.
- **Terminal tap** — the tapped tor is a bare-return (`f(x): r -> r`): the
  produced value *immediately leaves the frame*. There is no downstream.
  `produce → observe → return`. The observation goes **before** the return, and
  the return stays the **sole tail** — nothing is grafted after it.

The terminal case is the **simpler** one, not the harder one: there is no
continuation to thread, so there is *less* to do. The trap is that the weaver
only knew the mid-flow shape and forced "wrap-and-continue" onto a terminus —
grafting the original flow (which already ends in the return) as the tap's
continuation, so a second observer lands *under* the `RETURN` node and emits as
unreachable code after `return r`.

This is grounded, not theory — it is exactly the 508-green / 320-red split:

- `508` is green because `~compute(x: 21): r |> print.ln(...)` makes `compute`
  **mid-flow** — `print.ln` is the "after". Tap weaves cleanly.
- `320`/`322` are red because `~double = add-five(value): r -> r` makes
  `add-five` the **terminal** of `double`'s body. The tap has no "after", the
  weaver invents one, and the double-emit is that invention.

So the well-formed rule for the terminal case is a single sentence: **a tap on a
bare-return inserts its observation before the return and grafts no
continuation.** Observe the value on its way out, then return it — coherent for
one tap, for several taps in order, for a tap that reads the bound value.

**Open — deliberately parked, do NOT tangle into the bare-return fix:** whether a
tap may carry **effect branches** (a multifire `!` arm rather than a one-shot
observation — see [[frag-presence-effect-arm-expressions]] for what a multifire
arm *is*). That asks "can an observation fire 0..N times and rejoin the flow?",
which genuinely expands what a tap is. Bare-return taps are well-formed under the
two shapes above **without** deciding it. Keep the questions separate; conflating
them is most of why taps feel heavier than they are.

The pit this belief walls: treating a terminal tap like a mid-flow tap — reaching
for a downstream that a bare-return does not have, and synthesizing one. When the
tapped transition is a terminus, the weave does *less*, not more.

## The terminus with an obligation brings a THIRD actor (2026-08-08)

330_031 exposes the shape this fragment had not yet met: the tapped terminus is
an UNBOUND head whose bare return carries an obligation
(`~open(path:)`, `open -> *File<opened!>`, no `: r`). Two facts, measured:

- **Each pass mints its own synthetic name for the same value and neither
  consults the other.** The tap weave stamped `_tap_N` on its void wrapper — a
  binding the emitter never declares for a bare-return — while auto-discharge,
  running later, minted `_auto_N` for the head it saw as unbound. The tap step
  then referenced a name nothing declares. Fixed on the tap side: the weave now
  mints the HEAD's bind and hands it to the flow site to stamp as
  return_binding, so there is one name and it is the head's.
- **An observer-only flow has no exit the disposal machinery may legally
  use — and that is open, not fixed.** The wrapped flow's single continuation
  is the @scope observer; auto-discharge's terminal-disposal only fires at a
  real flow exit, discharge inside @scope is forbidden by design (an observer
  must not satisfy obligations), and appending a synthesized terminal sibling
  trips SHAPE002 in both structural checkers. So the composed program runs,
  the tap observes, and the obligation silently never discharges. The question
  this parks: WHERE is the flow exit of a flow whose author wrote only a
  terminus and whose every continuation was synthesized by an observer weave?
  The disposal wants to fire "after the observers, at the level of the head" —
  a position the current continuation grammar cannot spell.

Same lesson at a bigger radius: the weave, the discharge inserter, and the
shape walls each hold locally and compose into a hole, because no one of them
owns the composed flow's exit.
