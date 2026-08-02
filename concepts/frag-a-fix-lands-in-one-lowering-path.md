---
type: belief
id: frag-a-fix-lands-in-one-lowering-path
provenance: ecs-store row-tax session 2026-08-02 — the same rule body run down the store's two row-iteration lowerings, rf_stripe_N against rf_sweeps_N, which sat over 6x apart
ts: 2026-08-02
---

# A fix lands in one lowering path; the other keeps its old cost silently (belief)

When one construct has two lowerings, an improvement is not made to *the
construct*. It is made to whichever lowering the person was looking at. The
other keeps the old cost, and keeps it quietly, because nothing in a green test
suite has an opinion about how fast either one is.

The store reads its rows two ways — a query read at a program position, and a
standing rule fired by the scheduler — and both walk the same corpus doing the
same per-row work. They had drifted on three separate mechanisms at once, every
one of them the rule path lacking something the query path already had: the loop
form, the derived projection, and whether the row cursor is resolved when
nothing asks for it. None of the three was a bug anyone introduced. Each was a
place where an improvement was made once, to one side.

The loop form is the clearest instance because it had already been *learned*.
It was measured, believed, written down, and shipped for the query path; the
rule path kept the old spelling anyway, and nobody noticed for as long as the
two paths had existed. A lesson that has been fully absorbed into the project's
doctrine still does not propagate itself across a lowering boundary.

## Why the suite cannot see it

Correctness tests ask each path whether it produces the right rows. Both do.
Nothing asks the second path why it takes six times as long to produce them,
because no test compares two paths against each other — tests compare a path
against an expected output, and both paths have the same expected output.

This is the same absence that lets any performance divergence survive a green
board, but it bites hardest where two lowerings exist for one surface idea,
because there the divergence is invisible even to a careful reader: both
lowerings look reasonable in isolation. The gap only exists in the comparison,
so only a comparison can hold it.

## What follows

- **When a construct has two lowerings, the pair is the unit of work.** A fix to
  one is half-finished until the other has been looked at and either changed or
  written off with a reason. Treating "I fixed the sweep loop" as done is what
  produced this.
- **Keep a differential pin: the same program, both lowerings, raced.** The
  instrument that exposed all three divergences was a pair of benchmark ports
  running the *identical* rule body through the two paths. That shape is worth
  keeping deliberately rather than as an accident of the fusion study — it is
  the only thing that turns a silent cost into a number. This is the
  performance-side sibling of an A/B control test: not "is it right" but "is it
  the same".
- **Count the lowerings before believing a fix is general.** The question "how
  many ways does this construct lower?" is cheap to ask and was never asked. It
  should be part of scoping any emitter change, and the answer belongs in the
  change's own record.
- **Suspect the whole family, not just the sibling.** Once one divergence is
  found between two paths, the prior on more divergences between the same two
  paths is high — three were found in one sitting here. Finding one is a reason
  to enumerate, not a reason to fix one thing and leave.

## The open question

Whether the two lowerings should exist at all is not settled by any of this.
Convergence — one row-iteration lowering that both surfaces use — would make the
whole class of drift impossible, and is obviously the better end state if the
two paths' obligations really are the same. They may not be: the rule path is
scheduled, joins a stripe, and carries a cursor the query path does not need.
Until someone establishes that the obligations coincide, the differential pin is
the mitigation and convergence is the ambition, not the plan.
