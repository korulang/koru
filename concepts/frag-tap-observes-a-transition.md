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

## The observation record is testimony about the transition (2026-08-25)

The record a metatype tap builds (Profile/Transition/Audit) is not a log line —
it is **testimony**: it asserts, in vocabulary the reader takes on faith, what
kind of crossing happened. When that vocabulary contradicts its own definition,
the lie ships into every downstream profile and no test catches it, because
records are rarely asserted against.

Measured instance: bare-payload completions were spelled `__void` — the
void-completion sentinel — while an i32 crossed. Every `: r` step in a profile
read as "nothing crossed here". The 330_009/330_010 pins carried the right name
("result") from the day they were written and sat red for a month for it.

**The belief:** an observation record's fields must satisfy the same honesty
the flow-level walls enforce on values — the branch field names what crossed,
and a name defined as "nothing" may not label a something. Fix at the
construction site (the weave), never at an emitter's render, so every target
inherits the truth once.

**Open edge (parked):** unbound payload returns (`~greet(...)` discarding a
`-> string`) still spell the void sentinel today, because the weave only knows
a value crossed via the head's bind being in scope. Making those honest needs
the event's return type threaded to the weave and would re-pin green 310_018.
The question this parks: is "what crossed" determined by the event's TYPE or by
whether a NAME was bound? Type says result; binding-scope says void. They
disagree exactly when the payload is discarded.

## The observer-wrapped exit is answerable — and the walls pick its shape (2026-08-25)

The parked question above — WHERE is the flow exit of a flow whose every
continuation was synthesized by an observer weave? — has an answer now, and
getting to it took three refusals, each teaching where the settlement may
legally land:

- A body-level sibling after the observer trips SHAPE002: the weave leaves
  children under the observer, so it is not a flat sequential step.
- A graft under the bodiless implicit-terminal marker trips KORU105: nothing
  picks a branch under a branch that has no body.
- The same graft, unmarked, trips KORU032: the creditor reads any consume of a
  head-level debt inside the @scope boundary as an observer satisfying an
  obligation.

The resolution that satisfies all three: **the settlement REPLACES the
bodiless marker** (the marker only ever said "the flow ends here"; ending on
the consuming call says it with the debt settled), stamped
`@auto-exit-disposal` so KORU032 can tell the machinery's own flow-exit
settlement from an author-written discharge inside a scope. The distinction
the wall keeps is exactly the one this fragment drew in 2026-08-08: observers
observe; they never satisfy. What changed is that the FLOW may settle at their
end without that counting as the observer acting.

One engineering law this cost real memory to learn: **idempotence by
structural presence, never by context state.** The flow-level context
re-seeds every transform sweep and never sees walk-internal crediting, so a
"have I already discharged?" check against context state appends forever. Ask
the tree.

Open edge from the earlier section stands: unbound payload returns still spell
the void sentinel; type-vs-binding-scope still disagree when the payload is
discarded.
