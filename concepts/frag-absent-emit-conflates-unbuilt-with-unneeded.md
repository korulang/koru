---
type: belief
id: frag-absent-emit-conflates-unbuilt-with-unneeded
provenance: draining the 2026-06-07 registry triage queue 2026-07-26 — ten codes reserved and one retired; the lone-gap hint argued BUG hardest on KORU123, where the named condition is computed nowhere, and KORU082 turned out to be a duplicate carried since the initial commit rather than unfinished work
ts: 2026-07-26
---

# A set computed by subtraction holds conditions that want opposite dispositions (belief)

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

## The corpus has the same shape, and its discriminator is NOT computable

2026-08-06, a second subsystem, same form. The board's failure set is computed the
same way — everything that ran and did not pass — and it holds at least two
conditions wanting opposite actions:

- **unbuilt** — the desired behaviour is agreed and nobody has written it. Disposition:
  work. Any session can pick it up.
- **undecided** — nobody has ruled what the language SHOULD do, so there is no correct
  fix to write. Disposition: a decision, from the one person who can make it. No amount
  of effort clears it, and effort spent on it produces an invented answer, which is
  worse than the red.

**The difference from the registry case is the important part.** There, the
discriminator was computable — a same-description twin — which is why that Open asks
whether the watcher should just split the buckets itself. Here nothing can compute it.
"Waiting on a ruling" is a fact about a person's intent; no predicate over the tree
will ever find it. So the vocabulary has to let a human *declare* it, and a declaration
is exactly the thing this repo already knows goes unchecked
([[frag-a-red-pin-is-unfalsifiable-documentation]]).

What landed: a `RULING` marker file whose first line is the question, and
`prose-check:E`, which fails the run when the marker stops describing its test — the
one direction that IS mechanical. If the test passes, the claim is false: either the
question was answered and the marker outlived it, or the pin was measuring something
else. Deliberately NOT a status, so a parked question can never flatter the pass rate;
the test stays in the failure count and the queue rides alongside it.

**Two things the marker cannot do, stated so nobody assumes otherwise.** It cannot
catch a question that was never written down — an undecided red with no marker is
invisible, and the count is a floor, not a census. And it cannot tell whether the
question written is the *right* question, which is the same unfalsifiable-prose hole
one layer up.

**A vocabulary that is not in the allowlist does not exist.** The marker was invisible
to git on first write: `tests/regression/.gitignore` ignores every extensionless file
(`*`) and re-admits markers one name at a time, so eleven markers lived only in one
working tree until `!**/RULING` was added. Caught before shipping, and worth holding as
the general form — a new marker type is recognized by exactly the consumers that name
it, and the version-control layer is a consumer people forget is one.

## Open

Whether the watcher should split DEAD into the two buckets itself, given that the
twin check it already computes is exactly the discriminator. It currently prints
the duplicate as a hint and leaves the reader to infer the action.
