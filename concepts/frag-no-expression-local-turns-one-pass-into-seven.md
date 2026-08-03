---
type: belief
id: frag-no-expression-local-turns-one-pass-into-seven
provenance: written 2026-08-03 from the boids port and CORRECTED the same day when Lars challenged the claim and the measurement went the other way; the id keeps the original (wrong) name because ids are opaque and never renamed
ts: 2026-08-03
---

# Splitting a fat per-element computation into several passes is FASTER than fusing it, and the first explanation was backwards (belief)

## What this file said before, and why it was wrong

It claimed that the store's missing expression-local binding *forces* a
one-pass algorithm to become a seven-pass one, and that Koru pays for the extra
traversals. Both halves were false.

**A single pass was always available.** Chained writes inside one query arm run
per ROW, and each write sees the previous one's value for that row — `step-dyn`
in the same benchmark has been written that way since before boids existed. The
seven traversals were a structure I chose and then read back as a property of
the language.

**And the seven passes are the FAST shape.** Fusing them into one pass, same
arithmetic and same bit-identical checksum, is about 1.5x SLOWER. So the
supposed cost was not merely unforced, it was pointing the wrong way.

This was caught by being challenged, not by being tested, which is the part
worth keeping: the claim was assembled out of a structure I had authored, and I
never ran the alternative before generalising about the language from it.

## What is actually true

The benchmark now carries a fusion ladder — the same steering as seven passes,
as two-fused, as four-fused, and as one — all with the same checksum, so the
only variable is the shape. Cost is flat from seven passes to four, then rises
sharply when the whole body is fused. The degradation is NONLINEAR in body size,
not proportional to the number of traversals.

The mechanism is visible in the emitted code and is the durable finding: **a
multi-field write emits one write-path call per FIELD, and each call carries the
whole row's worth of value slots** — every column, with zeros in the slots it is
not writing. That is only free because the call inlines and the field selector
folds, at which point the dead slots vanish. A body small enough to inline pays
nothing; a body large enough to defeat whatever budget governs it pays for all
of them at once.

So the store's write path has a cost that is invisible at every size anyone has
tried and then arrives all at once. Which side of the line a program lands on is
not visible in its source.

## What remains open, and it is the interesting part

Why the fused body crosses the line is NOT established. Candidates, none tested:
an inlining budget; register pressure across a long live range; or the loss of
auto-vectorization once the body contains store-to-load dependencies through
columns. The ladder is the instrument that would separate them, and it exists
now.

Also unresolved: whether the expression-local binding is worth having at all.
The verbosity argument for it stands on its own — 12.7k characters of Koru from
about 40 lines of C# — but the PERFORMANCE argument that was originally attached
to it is dead, and it should not be revived without a measurement.

## The methodological residue

When a language lacks a way to say something, the temptation is to conclude that
the workaround you reached for is what the language forces. It is not: it is
what you reached for. The check is cheap and I skipped it — write the other
shape and time it. Both shapes belong in the repo afterwards, which is why the
ladder is committed rather than deleted once it had made its point.
