---
type: belief
id: frag-absent-emit-conflates-unbuilt-with-unneeded
provenance: draining the 2026-06-07 registry triage queue 2026-07-26 — ten codes reserved and one retired; the lone-gap hint argued BUG hardest on KORU123, where the named condition is computed nowhere, and KORU082 turned out to be a duplicate carried since the initial commit rather than unfinished work
ts: 2026-07-26
---

# A declared code nothing emits is two different facts wearing one label (belief)

The registry watcher computes DEAD as DECLARED minus EMITTED. That set is
honest and worth firing on, but it holds two conditions that want opposite
actions:

- **Unbuilt** — the detector was never written. The enum promises a check the
  compiler does not perform. Disposition: reserve, with the missing detector's
  shape named, or build it.
- **Unneeded** — the condition IS detected, under a different code. The
  declaration is redundant, not pending. Disposition: retire it.

`KORU082` had the byte-identical description of `TYPE003`, which has been emitted
since early on. It was never unfinished work; the enum had carried two names for
one condition since the initial commit. Reserving it would have filed a
duplicate as future semantics and made the redundancy permanent under a label
that stops anyone looking again.

## Emit-density does not predict detector existence

The watcher hints from sibling density: a lone gap in an otherwise-emitting family
is "almost always an unwired BUG." That heuristic is not merely weak — on this
queue it pointed **wrong exactly where it was loudest**.

`KORU123` sits in a family with five live siblings, and the machinery behind it is
real: the parser accepts the `|mlir` variant and the build synthesises AOT
requirements. Everything about its neighbourhood argues BUG. But nothing anywhere
asks whether a shape is generatable, so the condition it names is computed
nowhere — reserved. Density measures how much attention a family received; it says
nothing about whether one specific detector was ever built.

## What follows

- **Disposition from the detector, never from the family.** Grep for the SHAPE of
  the missing check — a visiting set over a call graph, a magnitude test on an
  indent — and never for the code's own name, which appears only where it is
  declared and therefore proves nothing.
- **Check for a twin before reserving.** Same-description siblings are the cheap
  discriminator between the two facts, and the one that flips the action.
- **A reserved code owes a shape, not a promise.** "Not built yet" is unfalsifiable;
  "nothing does an existence check at ControlFlow.registerLabel's `put`" can be
  re-checked by the next reader in a minute, and stops being true the day someone
  builds it.

Related: [[frag-evidence-must-count-the-same-thing-the-verdict-does]] — the same
tool's evidence surface inflated PINNED for these very codes, arguing for the
wrong disposition from the other direction.

## Open

Whether the watcher should split DEAD into the two buckets itself, given that the
twin check it already computes is exactly the discriminator. It currently prints
the duplicate as a hint and leaves the reader to infer the action.
