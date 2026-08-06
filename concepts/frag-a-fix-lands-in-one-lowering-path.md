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

## 2026-08-06 — the same drift in a CHECK, which is worse

Everything above is about cost, and it leans on *"nothing in a green test suite
has an opinion about how fast either one is."* That framing is too narrow.
**Reach drifts the same way, and reach is the worse case, because the suite does
have an opinion — it just holds it on one side.**

`phantom_semantic_checker`'s use-after-discharge wall reads a binding two ways:
as an argument (`show(h: r.k)`) and inside a `{{ }}` interpolation
(`print.ln("{{ r.k:s }}")`). Both were built deliberately; the doc comment says
the interpolation half "is the one that mattered." Yet a discharged RECORD FIELD
is caught in argument position and sails through interpolation, and the
four-cell table is what shows why:

    plain binding + argument       caught
    plain binding + interpolation  caught
    record field  + argument       caught
    record field  + interpolation  MISSED

Each half is right about the case its author had. The argument path keys on
composite names, because that is what a disposal set holds for a record field —
`r.k`, printed verbatim in its own diagnostic. The interpolation path tokenizes
identifiers and skips any segment after a `.`, on the stated and *generally
true* ground that "a trailing `.field` names a field, not a binding." **Two
halves of one checker had grown different notions of what a name is**, and
neither is wrong in isolation.

### Why a reach divergence hides better than a cost one

A cost divergence is invisible because no test compares two paths. A reach
divergence is invisible for a nastier reason: **three green pins say the wall
works.** `335_024`, `335_025` and `335_047` all pin use-after-discharge and all
pass — and every one reads its stale binding in argument position. The corpus
does not merely fail to cover the fourth cell; it reports that the wall is
tested, because it is, on the axis somebody happened to write.

So the rule generalises past lowerings: **when one guarantee is enforced at two
sites, coverage is the CROSS PRODUCT of sites and shapes, not the union.** A pin
per site reads like coverage and is not. Writing the table and looking for the
empty cell cost one probe here, and had gone unasked for as long as both halves
existed.

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

## The fourth tell is a DISCRIMINANT, and it defeats the "count the copies" grep

Every form above assumes the duplicate sites are findable: two functions, four
`storeRefs` copies, N scanners, the terms of a sum. All of them answer to this
belief's own prescription — grep the name, count what comes back. The form found
on the `=>`-target wall does not, and that is the whole reason it needs writing
down.

There the second site is not a second function. It is **the same function, the
same block, three lines further down, behind a kind test.** One arm of a
discriminant got the wall; the sibling arm fell through to a stub. Grep for the
resolver's name and you find one call, in one place, looking correct — the count
comes back *one* and the count is right. Nothing about counting copies reaches a
rule that is present-but-gated, because the gate is not a copy.

So the diagnostic question has to change shape. Not "how many places implement
this?" but **"over what does this check quantify, and what does its guard
exclude?"** A wall inside a conditional is a wall over that conditional's true
branch only, and the else is invisible to every technique this belief has so far
recommended.

- **A guard is a scope, and a scope is a boundary this belief already knows to
  distrust.** `if (kind == .effect)` is doing the same work as a private helper
  struct inside a transform: silently narrowing who a fix reaches, while reading
  as ordinary code organisation.
- **Read the guard against the failure, not against the feature.** The stated
  reason for that wall — an unknown name would otherwise reach the host as a
  malformed union construction — is a property of *constructing a name at all*.
  It has nothing to do with the branch's kind. When a guard is narrower than the
  reason written directly above it, the guard is the bug.

## Why this class outlives every instance: the immune system is single-path

The instance above is the ninth. That number is the finding, not the instance,
and this belief has not so far said why the count keeps climbing.

**Every mechanism this project uses to hold a class is a test, and a test walks
one path.** A pin states "this program behaves so". The class states "these two
paths agree" — which is not a property of any single program, so no pin can carry
it. The corpus can therefore be complete, green, and honest about every path it
names, while saying nothing whatsoever about the invariant that matters. That is
not a coverage gap to be closed by more pins; it is a category mismatch, and
adding pins of the same shape cannot retire the class no matter how many are
added.

The evidence that this is structural rather than sloppy is that the wall, the
doctrine, the marker vocabulary, and the pins all *already existed* for the
enforced path — and the sibling had none of them. Nobody skipped a step. The
steps, taken correctly, do not reach across a path boundary.

- **A differential instrument is a different KIND of test, and it is the only
  thing that holds this class.** Same program, both paths, results compared. The
  project owns one, for one construct, and a near-miss: a mirror cluster built to
  compare a program moved between MODULE and ENTRY-FILE placement. That is the
  correct instrument aimed at the wrong axis — placement rather than path — and
  it was the most productive instrument here by a wide margin, which is the
  argument for aiming it at the other axis too.
- **Suspect a memorial.** The most reliable signature of this class is a comment
  or test header describing the failure in the past tense, on the path where it
  was fixed, while the sibling path still produces it. A gravestone is evidence
  that someone understood the defect completely — which is exactly the condition
  under which the second path gets forgotten, because understanding it felt like
  finishing it.
- **The author of the report is inside the failure.** Meeting the ungated path
  produced a confident write-up naming it a missing language capability, in the
  words this belief predicted ("filed as a language limitation"). A belief that
  describes the reader's own error in advance and does not prevent it is not
  weak — it is unenforced, and the gap between a written belief and a firing wall
  is where all nine instances live.

## The fifth tell is POLARITY, and the twin is written in the wall's own comment

The forms above all involve two sites doing the same job. This one has two sites
doing MIRRORED jobs, where only one got the guard — and it is the cheapest of all
of them to find, because the missing half is spelled out in the prose of the half
that exists.

The regression harness refuses a negative test that names no diagnostic, on the
stated grounds that such a test passes on ANY failure and therefore keeps passing
long after the diagnostic it meant to pin has been replaced. That reasoning is
about *unconstrained agreement between a verdict and an expectation*, and it is
polarity-neutral. The positive twin — a test that demands a clean run and names no
expected output — passes on ANY output, for exactly the same reason, and there is
no gate for it. Measured 2026-08-04: 72 of 1052 such tests name nothing.

What makes this worth its own tell is the discovery method. Finding the earlier
forms took a race, an arity probe, or a scope audit. Finding this one took
**reading the existing wall's comment and negating the nouns.** The comment is a
general argument that happens to be filed under one case; the other case is
implied by it and absent.

- **When a wall's justification does not mention the polarity it is written for,
  the other polarity is missing and nobody noticed.** Ask it of every gate: is
  this argument about *this* form, or about a property both forms have?
- **A cheap green is worth less than a red, and looks like more.** Both halves of
  this pair fail the same way — they convert "no expectation was stated" into
  "expectation met" — and that is strictly worse than an untested program,
  because it occupies a slot in a count someone publishes.
- **A reporting tool over an unwalled corpus inherits the corpus's dishonesty.**
  Written to find TODO-marked tests that had quietly started passing, the first
  sweep found three passes and zero real ones: two were bare `MUST_RUN` tests
  printing the very error their own note says they are parked on, and exiting 0.
  Had the sweep trusted the verdict it would have reported three features shipped
  and closed three notes describing live bugs. **A tool that reads verdicts must
  ask what each verdict is allowed to mean**, and when it cannot, report the
  weakness instead of the number.
## The untouched lowering is the one on the front page (2026-08-05)

Fresh instance, and it moves the belief on two axes at once: the count can be
**four**, and *which* lowering goes untouched is not random.

`std/io`'s print surface was made freestanding-capable so Koru could print
inside a Unikraft unikernel. The fix went into `__printInterpolate`, which is
shared by `print`, `print.ln`, `eprint`, and `eprint.ln` — four user-facing tors,
one implementation. That reads like the general fix, and it was reported as one.

It was a quarter of the change. `print.blk` is a **separate** implementation with
two lowerings of its own — `|zig` and `|raw_posix` — each carrying a `:f`/`:any`
fallback, and the raw path a hand-rolled `__kz_w` besides. Four write sites
total; one was fixed.

The bias is the part worth keeping. The author's own probe was a `.kz` file
calling `print.ln`, so the fix was verified against exactly the lowering the
author reached for. **`print.blk` is the surface on the korulang.org front page**
— it is what `010_000_hello_world_koru` uses, it is what pure `.k` looks like,
and it is the one a first-time reader meets. The untouched lowering was not an
obscure sibling; it was the canonical one. "Which lowering was I looking at" is
not a coin flip, it is *whichever one the author's habits use*, and an author's
habits are systematically not a newcomer's.

What surfaced it was not a count and not discipline. It was a request to run the
same thing through the *other* front door — "test it with pure Koru too, a `.k`
file" — which found the gap in one move, before any of the four sites had been
enumerated.

- **Ask for the other front door, not just the other lowering.** Counting
  lowerings is an implementation-side question and it is easy to answer wrong
  when two surfaces share a name. "Run the same program through the surface I do
  NOT habitually write" is cheaper, needs no map of the emitter, and lands on the
  user-visible ones first.
- **Weight the count by who meets each path.** If one lowering is the front-page
  example, it is not one of N — it is the one that must work, and a fix that
  skipped it has not shipped regardless of how many sites it covered.
- **Converge the text, not the discipline.** The mitigation here was not a rule
  to remember: the four sites now splice one `KORU_OUT_UNESCAPED` const, with the
  brace-escaped variant *derived at comptime* rather than hand-maintained beside
  it. Two hand-kept copies of one string is the same defect one level down, and
  the earlier sections of this belief are a list of times that bill came due.
