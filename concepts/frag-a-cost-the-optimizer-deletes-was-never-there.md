---
type: belief
id: frag-a-cost-the-optimizer-deletes-was-never-there
provenance: the ecs-store row-tax decomposition scheduled a 3.91x "projection" rung off a Zig mock; removing the projection for real produced byte-identical machine code on all six rule ports
ts: 2026-08-02
---

# A cost the optimizer deletes was never there, and only the codegen can say so (belief)

A hand-written mock in the backend language is a *different program* from the
one the compiler emits, and the difference that matters is not the source — it
is what the optimizer can see. Emitted Koru threads a row through nested
`inline` event handlers; after inlining, values that no reachable code consumes
are dead, and LLVM removes them along with the loads that produced them. A mock
that reproduces the *shape* of the emitted code without reproducing its
*inlining structure* keeps those loads, times them honestly, and reports a cost
the real compiler never pays.

The corpus already held "kill hypotheses in the mock, confirm in the compiler."
That is necessary and it was not sufficient: it guards against a mock that
fails to reproduce a real cost, and says nothing about a mock that
**manufactures** one. A manufactured cost is worse than a missed one, because
it survives review — it is a number, it is reproducible, and it points at real
code that really does the wasteful-looking thing. It went onto the board as the
largest scheduled prize and stayed there for a day.

## What follows

- **For "does this change cost anything", the instrument is the emitted machine
  code, not a stopwatch.** Build both ways, disassemble, diff. Byte-identical
  assembly cannot run at different speeds — that is a proof, not a
  measurement, and it needs no quiet machine, no repetitions, and no
  statistics. It is also *cheaper* than timing.
- **Reading the emitted source is not enough; read what the backend made of
  it.** The nine dead loads were plainly visible in `output_emitted.zig` and
  plainly absent from the binary. Emit-level reasoning is where this class of
  error is born.
- **When codegen genuinely differs, interleave the two binaries in one
  process loop** — alternate A,B,B,A and compare medians. Sequential passes
  minutes apart cannot resolve a 10% effect on a shared machine: an untouched
  control moved by the same factor as the change under test, which is how the
  drift was caught rather than believed.
- **A control that moves with the treatment condemns the run, not the
  treatment.** The query-path ports share nothing with the rule-path change;
  when they moved 1.12x too, that was the whole answer.
- **Ordering a work list by mock-derived numbers orders it by an artifact.**
  Size the rung against the real compiler before it becomes "the prize".

## Closed, same day: the ordering WAS exactly backwards

The handle rung landed and measures **5.70x** and **5.77x** on the interleaved
instrument, with the query-path controls byte-identical. The mock priced it at
**1.22x**. Set against the projection it priced at 3.91x and which is worth
nothing, the decomposition was not merely imprecise — it was inverted. Its
smallest term was the whole prize and its largest term did not exist.

So the answer to the question above is the uncomfortable one: **the mock's
error was the method, not one bad variant.** A mock reproduces the shape of
emitted code and never its context, and the two failures have one root seen
from opposite sides. It kept dead loads the optimizer deletes — inventing the
projection cost — and it modelled the handle round-trip as arithmetic when in
the real store it is a four-deep chain of dependent loads behind four panic
branches, which does not merely cost cycles but makes the loop
**unvectorisable**. That is not a quantity a mock gets wrong by a factor. It is
a property of the surrounding code that a mock does not have.

**The tell was available before any of the measurements**, and it is cheap
enough to make routine: four instructions of `fadd.2d` against twenty scalar
ones. Instruction SHAPE separated the terms correctly where the mock's timings
ranked them backwards. Read the two loops before modelling either.

## Open

Whether anything else on that board rests on a mock. The decomposition is now
fully re-derived, but it was not the only probe written in Zig against a
hand-modelled store, and the ones that produced retractions — prefetch, the
capacity lever — were believed for a while first. A mock that KILLED a
hypothesis is safe; a mock that ESTABLISHED a number is suspect until the
codegen agrees.
