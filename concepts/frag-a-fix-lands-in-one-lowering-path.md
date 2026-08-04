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

## The same shape without lowerings: N hand-rolled scanners for one rule

"Two lowerings" turned out to be the narrow case. The general one is **a rule
with no single implementation site**, and it is worse, because there is no
boundary to count across — nothing tells you how many sites exist.

"Inside a string, `\` escapes the next byte" is such a rule. Three scanners in
the compiler implement it independently, each spelled differently, and each was
found by a different program: the argument comma-splitter, the paren-finder,
and the colon scanner that decides `name: value` (210_196 now carries all
three).

What makes this instance worth keeping is that the second fix **already knew
about the first**. 210_196's header names two scanners and describes how each
got the rule wrong. The author saw a duplicated rule, fixed both known sites,
and pinned one program — and the third site survived, for months, in the
function that decides what an argument's NAME is.

So knowing about duplication does not, on its own, produce a search. What
follows:

- **The moment you find a rule implemented twice, the deliverable is the
  COUNT, not the second fix.** "Two scanners had this bug" is a sentence that
  should not be written until someone has grepped for the third. It is cheap;
  nobody did it, twice.
- **A pin written at the fix covers the spelling that found the bug.** The
  escape rule fails on a PARITY property — an even number of escaped quotes
  lands a broken tracker back inside the string by accident, so it behaves
  correctly. 210_196's original program had an even count. It was a true pin
  of a real bug and it was structurally incapable of catching the third site.
  When a defect has a parity or counting character, the pin must carry both
  parities or it pins a coincidence.

## The tell is ARITY, and it is cheap to read

The original sitting found two lowerings by racing them for speed. There is a
much cheaper signal, and it showed up on the same construct one write later:
**a feature that works for one field and not for two.**

`stored` has two lowerings — a single write, and a plural envelope. A
handle-addressed READ in the value had been installed in the single one. So
`stored { p.a: cells[h].v }` compiled and `stored { p.a: cells[h].v, p.b: … }`
did not, and the failure named an undeclared host identifier rather than
anything about arity.

Arity is almost never a property of a *feature*. Nothing about reading a column
through a handle cares how many fields are being written beside it. So when
behaviour changes with the number of fields, the number of arms, or the number
of branches, the thing that changed is **which code ran** — a dispatch, not a
capability. That reading takes seconds and it points straight at the second
lowering.

It also explains why the corpus could not see it, and this is where this belief
meets `frag-a-corpus-exercises-its-authors-idioms`: **every pin for the indexed
read is single-field.** A pin exercises one lowering by construction, so a
corpus of pins is structurally incapable of comparing two. The green board was
honest about the feature and silent about its coverage.

- **When a fix is arity-sensitive, stop and count the lowerings** before
  believing anything about the feature.
- **Converge rather than patch.** The fix here deleted the branch — both arms
  now call the same lowering — because a second copy that merely agrees today
  is the same bug waiting.

## The second tell is SCOPE, and it is why the same feature can be missing entirely

The two tells above — a speed gap, an arity gap — both assume the second
lowering *does* the thing, worse or narrower. There is a blunter case, found
closing the grid's read surface on 2026-08-03 and pinned aspirationally as
690_250: the second path does not do it at all, because the function that does
it is **out of its scope**.

`indexedFieldRefs` is complete. It recurses, it handles nested indices, it is
the subject of its own pin. It also lives inside the helper struct scoped to
the `stored` transform, and the whole-program walk that `std/store:new` runs
carries a *different* helper struct — one holding only the singleton-path
rewriter. So a handle-addressed read lowers in a write block and nowhere else,
not because anyone decided that, but because the two walks were written in two
places and each grew the rewriters its author needed. store.kz holds four
separate `storeRefs` copies in four scopes; that number is the mechanism.

What this adds to the belief: the drift is not only in what a lowering DOES,
it is in what a lowering can REACH. And the capability form is in one way worse
than the cost form this concept was written about — a silent 6x at least runs.
A missing rewriter produces a backend error in a program position that has
nothing to do with the duplication, so the author reads it as "this expression
is unsupported" rather than "this path never got the fix", and files it as a
language limitation. That is exactly how it was recorded the first time it was
seen.

- **A private helper struct inside a transform is a lowering boundary**, even
  though it looks like ordinary code organisation. Anything defined there is
  invisible to every other pass in the same file.
- **Count the copies before believing a rewriter is the rewriter.** `grep` for
  the function name; if it appears in more than one scope, the feature is
  present in some of them.

## The third tell is a COMPOSITE VALUE, where the sites are terms, not code

Every form above has the duplicated sites in *code* — two lowerings, four
`storeRefs` copies, N hand-rolled scanners. The count is at least in principle
greppable. The nastier instance has no second site to find, because the site set
is the **terms of a value**.

A benchmark sink assembled from several counters is one number with several
authors. When a correction has to be applied to the measurement — discard a
warmup frame, exclude construction, scrub an artifact of setup — it is applied
to whichever term the author had in mind, and the others go on measuring a
different window. `archetype_churn_world`'s sink is this: the warmup discard
covered the checksum and left the counts, so one published figure summed two
incompatible windows.

Why this is worse than the code forms, and it is the whole reason to write it
down: **a composite value hides its own arity.** Two lowerings are two
functions; a reader can see there are two. A sink is a single integer at the
point of use, so nothing about reading it — or comparing it, or disagreeing
with it — reveals that a correction reached a quarter of it. The instrument
that exists precisely to catch partial work is structurally the thing least
able to report that it was partially corrected.

- **When a correction applies to a measurement, enumerate the measurement's
  terms first.** "I reset the checksum" is the same sentence as "I fixed the
  sweep loop", and it is wrong in the same way.
- **Prefer scrubbing the whole accumulator to scrubbing a field.** The reset
  here should have been "zero the stats", a statement about the record, rather
  than "zero the checksum", a statement about one author's concern. Corrections
  aimed at a *thing* survive the thing growing a fourth field; corrections aimed
  at a *field* do not.
- **A load-bearing correction and a gratuitous one look identical.** This
  warmup frame had to stay — it burns off a change-detection artifact of
  spawning, and three sibling scenarios in the same file had their warmups
  deleted as unfairness. Reading the source cannot separate "this discard is
  required" from "this discard is a leftover"; only measuring what the discarded
  frame contributes can. So the reflex on finding an odd-looking correction is
  to *measure its contribution*, never to remove it for looking odd.

## The enforcement layer is not exempt from the rule it enforces

Every form above is about ordinary code. The sharpest instance is not: the
`commit-msg` gate that exists to make partial belief-work impossible was itself
doing partial belief-work, and had been since it was written.

It validated a declaration's SHAPE — the verb is legal, the required fields are
present, the referenced blobs resolve — and never asked whether the declaration
COVERED the commit. So a commit could stage twenty-five concept files, declare
one, and the other twenty-four rode through undeclared. The staged set is an
aggregate whose size the gate never counted, which is this belief's third tell
exactly, wearing the uniform of the thing that enforces it.

Why this is worth its own section rather than a fourth bullet on the list:

- **A gate you can satisfy without doing the work is worse than no gate**, because
  it certifies. An absent check leaves you uncertain; a check that passes tells
  you the thing was examined. The 25-concept commit is now on the record as
  reviewed by a wall that looked at one file of it.
- **The rule was known, written down, and being applied elsewhere that same day.**
  This is the same shape as the loop form in the original instance: measured,
  believed, shipped for one path, and the second path kept the old spelling
  anyway. A lesson fully absorbed into doctrine does not propagate itself into the
  doctrine's own enforcement.
- **The tell generalises, and it is cheap to ask.** For any wall: does it check the
  SHAPE of a claim, or the claim's REACH over what it is claiming about? Shape is
  the easy half and the half that gets written, because it needs nothing but the
  message. Reach requires knowing what the commit touched, which is one more
  query nobody makes.

What follows for building walls at all: **a wall's own first test should be the
defect it was built to catch, aimed at the wall.** Both clauses added here were
negative-tested — a multi-file declaration naming a subset, and a custody move
that edits — before either was trusted, because a wall that has only ever been
seen to pass is indistinguishable from one that always passes.