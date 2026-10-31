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

## The sixth tell is an ENUMERATED MEMBER LIST, and it defeats every technique above (2026-08-06)

Every form so far has a *thing* to find. Two lowerings are two functions. Four
`storeRefs` copies answer to a grep. A discriminant's other arm is three lines
down. A composite value has terms. All of this belief's prescriptions —
count the copies, read the guard, race the paths, try the other front door —
presuppose that the missing work exists somewhere as text you can locate.

`std/store:new`'s whole-program cell-path rewrite has no such text. It is a
`switch` over AST node kinds, and it is complete exactly over the prongs someone
wrote down: a guard's `condition`, an invocation's args, an `Expression` arg's
captured text, a template's frozen `inline_body`, an `inline_code` node, a
produce arm's `.expression`. The branch-constructor node — `| then => got s.n` —
was not in the list. Nothing was duplicated, narrowed, or gated. **The defect is
an absent prong, and absence has no name to grep for.**

That is why every prong in that list arrived the same way, one per incident, over
months: valid Koru, a raw identifier in the emitted Zig, a diagnostic naming no
Koru construct. `.expression` came in at 110_022. `inline_body` at 690_074. The
branch payload at 690_256. Each was reported as "this expression position is
unsupported" — the language-limitation misreading this belief already predicts —
and each fix widened the enumeration by one without anyone asking what the
enumeration was supposed to be closed over.

So the diagnostic question changes shape again. Not "how many places implement
this?" but **"what is the closed set this switch must cover, and who guarantees
it stays covered?"** Zig will not: the `else => {}` that makes the switch
exhaustive is the same `else` that swallows every future node kind. An
enumeration with a silent default is a wall with no reach clause, and this
belief's own enforcement-layer section says what that is worth.

### The memorial fired twenty lines away

This belief's "suspect a memorial" bullet was written as a heuristic for
searching. Here it was not even a search: `rewriteImmediateImpl` sits
*immediately below* `rewriteNode` in the same anonymous struct, and its
doc-comment is a past-tense gravestone for this exact defect —

> A bare-return subflow (`peek -> s.v`) is not a Flow at all — it lands as an
> `immediate_impl` whose BranchConstructor carries the produced expression.
> Reading a cell there is as ordinary as reading one in an arg, but the walk used
> to visit only `.flow`, so the reference went to the host verbatim and Zig
> reported an undeclared `s` (110_022).

Same payload type, `BranchConstructor`, in two carriers. One carrier got a
handler and a memorial; the other kept emitting `use of undeclared identifier
's'`. The author of the 110_022 fix understood the defect completely — the
comment proves it — and that understanding is precisely what made the sibling
carrier feel handled.

**A gravestone naming a TYPE is a search key.** When a memorial says "reading a
cell in a BranchConstructor", the next question is "how many node kinds carry a
BranchConstructor?", and it is answerable from `ast.zig` in one read. Nobody
asked, twice.

### The differential instrument is two builds, not a project

This belief has asked five times for the thing that holds the class — same
program, both paths, results compared — and has each time described it as an
ambition. On this fix it cost two builds, and the recipe generalises:

> **Make the arm you just added inert, then go find a program that still needs
> it.** No such program exists → you added dead code. One does → that program is
> the second test, and you have just proved both copies are load-bearing.

Applied here: the singleton and plural walks each got the missing prong. Making
the singleton arm inert and re-running found that a program declaring a PLURAL
store above the singleton still compiles — because both walks rewrite *every*
store name in the program, so whichever `new` transform runs first does all the
work and the later one no-ops. Declaration order is the discriminant, and it is
not a variable anyone would have thought to vary. That program is 690_257;
690_256 is its singleton-first twin, and with only the plural arm it still
fails. Two tests, two arms, each measured rather than assumed.

The general point is that the differential instrument does not require racing,
benchmarking, or a mirror cluster. **It requires being willing to break your own
fix on purpose before you believe it was needed.** That is cheap, it is available
at the exact moment the knowledge is freshest, and it converts "I widened both
copies for symmetry" — an unfalsifiable good intention — into two pins.

## The seventh tell is a HALF-RULE: two scopes each holding the part the other needs

Same file, same afternoon, one gap further along. Closing the sixth tell's
enumeration got the branch payload lowered; the position audit it forced then
surfaced the reach gap this concept already knew about — `indexedFieldRefs`
complete inside `stored`'s helper struct and invisible to `new`'s whole-program
walk, recorded here in "the second tell is SCOPE". Moving the rewriter to file
scope and calling it from both walks is the obvious fix and it is not the
finding.

The finding is what fell out of the five copies of `storeRefs` once they were
put side by side. **Two of them excluded a following `[` from the one-column
identity case. Three did not.** The two that did carried a comment saying why —
"`[` is excluded so a row index still takes the indexed path below" — and those
two were exactly the copies that HAD an indexed path below them. The other three
omitted the exclusion, correctly, because in their scope no indexed rewriter
existed for the base to be stolen from.

So neither group was wrong. Each held **half of one rule**, and each half was
correct precisely as long as it stayed in its own scope. That is a new failure
mode for this belief, and a worse one than everything above it:

- **Every earlier tell has a wrong side.** One lowering is slower, one arm is
  ungated, one prong is missing, one term is uncorrected. You can read the two
  sites, decide which is right, and copy it across.
- **A half-rule has no wrong side to find.** Read either copy against its own
  scope and it is correct and its comment is accurate. The defect exists only in
  the *transition* — the moment the indexed rewriter arrives in the walk's scope,
  the walk's `storeRefs` silently becomes wrong, and nothing in either half says
  so. It is a latent conflict armed by a future fix, and it arms itself.

**What makes it findable, and it is not diligence.** The half-rule surfaced
because the convergence forced all five copies into one diff. Nothing else in
this project's practice would have shown it: the copies are hundreds of lines
apart, they had never been read together, and a grep for the function name
returns five correct-looking implementations. **Convergence is not only the
mitigation this belief keeps recommending — it is a DIAGNOSTIC, and the diff it
produces is where the half-rules are.** That is an argument for converging
duplicated code even when no bug is suspected, which is stronger than anything
this concept has said about duplication so far.

- **When merging N copies, do not diff them for equality — diff them for
  PRECONDITIONS.** Equality tells you which body to keep. The interesting output
  is a guard present in some copies and absent in others, because that guard is
  a claim about the scope, and merging the scopes invalidates it.
- **A comment explaining a guard is naming its precondition.** "so a row index
  still takes the indexed path below" is not documentation of the guard; it is
  the guard's dependency, written down, in the only place a reader would find
  it. Copies without the guard are copies without the dependency, and moving
  code between them without reading that sentence is how the transition breaks.
- **Count the copies, then count the DIFFERENCES among them.** This belief has
  been saying "count the copies" since its second section. The count here was
  five, which is the sentence that would have been written; the useful sentence
  is "five copies, three variants, and the variation is a precondition."

### I did it to myself, in the same sitting, thirty minutes after writing the tell

The convergence above merged two functions named `fieldOrder`, in two helper
structs, with identical signatures and near-identical bodies — one read three
sources, the other two, and the three-source version looked like the strictly
better one. It is not. It answers a **different question**: the insert SURFACE's
columns, which exclude a `[tree]`-synthesized `parent`, because a tree row's
parent is set by reparenting and never at insert. The other answers "every
column the cell holds".

Merging them turned all five `695_STORE_TREE` tests red — the only cluster in
the corpus where the two answers differ. The fix was to keep both, under names
that say which question they answer (`storeFieldOrder` / `storeInsertOrder`),
which is what the difference had been trying to say all along by existing.

Three things this adds, and they are the reason it is written down rather than
quietly fixed:

- **The half-rule tell has a twin on the merge side.** Diffing copies for
  preconditions catches a guard one copy lacks. It does NOT catch two functions
  that share a name and differ *by intent*, because there the extra clause reads
  as the more complete implementation. The question to ask before merging is not
  "are these the same code?" but **"are these the same question?"** — and the
  cheapest way to answer it is to look for a case where the two would disagree,
  which here is one word: `parent`.
- **Writing the belief down did not prevent the instance.** The half-rule
  section above was written, in this file, before the merge that broke the tree
  cluster. This concept has already observed that "the author of the report is
  inside the failure"; that observation now has an instance where the author had
  just finished authoring the warning. **A belief is not a wall**, and the gap
  between the two is not closed by making the belief better written.
- **What actually caught it was the full board, and nothing smaller would
  have.** The 690 cluster stayed green through the break — 162 passing, both
  target pins flipped, every control intact — because the divergence lives
  entirely in 695. A convergence changes the blast radius of a fix from "the
  thing I touched" to "everything that shared the code", and the verification
  has to widen with it. Running the affected cluster is right for a fix and
  wrong for a merge.

## Second instance — divergence is not only cost, it is behavior (2026-09-26)

The belief predicted silent *cost* divergence between sibling lowerings.
`400_198` showed the same shape for *correctness*: 400_076 had fixed
effect-branch chained invocations at dispatch top level, and the arm-body
path (`emitSubflowContinuationsWithDepth`) kept the old absence — it emitted
`handler(input, struct {})` and dropped the `!` arm into a result switch
whose Output union has no such tag. Same construct, two lowering paths, fix
landed in the one being looked at. The widened claim: anything a lowering
path *does* — a transform, a diagnostic, a fix — exists only in the path it
was written in; sibling paths share the surface and none of the substance.

## Third instance — the SAME fix, one driver position over (2026-09-30)

The sharpest instance yet, because it is not a sibling feature that missed
a fix — it is the *same bug*, fixed hours earlier on the sibling path, with
the fix commit itself naming the untouched path.

`#label` loops have two driver positions: flow-head (`run = #L tick(...)`)
and mid-chain fold (`seed(): s |> #loop step(n: s)`). Both share
`ctx.current_label` as the ambient "what does `.terminal` break" state in
`emitter_helpers.zig`. 548aae02b set it on the flow-head switch, which made
a *nested* `.terminal` — the implicit continue of an omitted `| ?else`
inside a `for` `! each` body — lower to `break :L` and exit the whole loop.
43d9a380f removed it from the flow-head path and said, in the commit
message: "the mid-chain fold path keeps its current_label, as before." The
justification written beside it — "every arm is inside the loop now, so
`.terminal` -> `break :label` is correct for each" — is true of arm
TOP-LEVEL terminals and false of terminals one nesting level down, where
"end this nested chain" is not "exit the fold."

320_171 pins the hole: identical program in both positions, `if` with no
`else` inside `for ! each` inside the looping arm. Flow-head prints
`hit 1:2 / hit 2:2 / hit 3:2 / done 3`; mid-chain prints nothing — the
first `i=1` iteration takes the absent else's `break :loop` and leaves the
fold before `| done` ever runs. Controls confirm the width: the each-body
without the `if` is green, and the same `if` *with* an `| else` is green —
the divergence is keyed on the optional arm's absence, exactly the
`.terminal`-mints-where-nothing-was-written mechanism the flow-head fix
described.

What this adds that the earlier instances did not have:

- **The memorial was written in the fix commit itself.** "The mid-chain
  fold path keeps its current_label, as before" is a past-tense sibling
  named at the moment of fix — the "suspect a memorial" bullet above, fired
  from inside the commit message, twenty-four hours before the pin landed.
  The invariant this belief has been asking for — *when a construct has two
  lowerings the pair is the unit of work* — was one grep away: `|` a label
  loop's two drivers into the same nested-terminal probe.
- **The ambient-state carrier is the boundary.** Neither path calls a
  "break the loop" function at the nested site; both consult
  `ctx.current_label`, and each path chooses whether to install it. The
  drift lives in the install decision, not the `.terminal` arm — two
  lowering paths that share a mutable context field are two lowerings in
  the sense this belief means, even though the code they share is five
  lines of `save/set/defer-restore`.
- **The fix is depth-shaped, not position-shaped.** Flow-head emits nothing
  for nested terminals because its arms never need `break :label` — exit is
  `-> T` return or `continue`. Mid-chain DOES need it at arm top level (an
  arm ending without `@loop` leaves the fold) and does NOT need it inside
  spliced sub-constructs. The correct rule is "`.terminal -> break :label`
  only at fold-arm depth 0", which neither path currently states — one side
  over-suppresses nothing (correct by accident), the other under-scopes the
  label (the pin).

## Fourth instance — the shared predicate was the divergent copy (2026-10-18)

Every text rewriter that maps `<store>.<field>` onto the cell path asks the
same question before rewriting a name: is the character before it a dot?
`x.world` must not become `x.__koru_store_world` — the member path is not
the store. That question was inlined at seven sites (store.kz, srefscan,
insert, ixrefs, gate, qrewrite, new's identRefs) as the literal expression
`(i == 0 or text[i - 1] != '.')` — and every copy misread `0..world.dd`
the same way: `..` is the range operator, `world` is a fresh operand, and
a dot immediately before the name is not always a member dot.

The misread was discovered through its symptom — `for(0..world.dd)` emits
`world` undeclared while `if (world.dd > 0)` lowers fine — and presented
as a missing walk position, the pattern this whole file documents ("every
gap this walk has ever had was an arm that was not here"). It was not a
missing arm. It was the guard itself, identically wrong in every copy.

What this instance adds:

- **The copies were a predicate, not a lowering.** The file's earlier
  tells count divergent *behaviors* — cost, emission, semantics. This one
  is smaller: a five-token boundary test pasted seven times, and the paste
  carried the misread to every site that pasted it. The bug did not drift
  BETWEEN copies — it was born in all of them at once, because "not
  preceded by a dot" reads like it means "not a member" and doesn't.
- **The fix IS the file's own prescription.** `precededByMemberDot` in
  ast.zig, next to `identBoundaryBefore` — one predicate, every call site
  changed to call it. Odd dot counts are member dots; exactly-two is the
  range operand (`x...name` = `x .. .name` re-arms the refusal — a
  leading-dot literal). A rule subtle enough to get wrong seven times is
  subtle enough to write once.
- **`identBoundaryBefore`'s comment predicted it.** "every text rewriter
  in the compiler needs it and there are a dozen private helpers to get
  it wrong in a dozen ways" — written about the boundary half, while the
  member-dot half sat beside it in exactly the shape it described.

Pinned at 690_371: `for(0..world.dd)` prints three times; the member-dot
refusals (row-binding shadow, cross-store index, all covered positions)
verified green on the 10-pin slice.

## Fifth instance — the emitted form the parser cannot read back (2026-10-18)

An indexed char-column read `rows[h].dir` lowered through `storeIndexedRefs`
to `(&__koru_store_rows.dir)[__koru_store_rows.__koru_resolve(h)]` — a `[N]u8`
array. Downstream, `rewriteZigExpr` is supposed to wrap `x == "lit"` in the
`std.mem.eql` block; `ZigExprParser.parseUnary` accepts `!` and `-` but not
`&`, so `(&arr)[resolve] == "lit"` is NoParse and the whole condition ships
to the backend raw — `cannot compare strings with ==`. Meanwhile
`store.prewrite.kz`'s `entityRefs` had already settled the correct shape for
the same read in `stored` value position: `sliceTo(&(&col)[idx], 0)` — the
slice, the same form the qrow projection binds. Two paths, one read, two
emissions — and the wrong one was wrong twice: unparseable to the rewriter,
uncomparable to the backend.

The second half of the instance is the file's older tell verbatim: insert's
seed fields lower through a LOCAL `storeRefsAll` inside `store.insert.kz` —
a partial copy of `StoredScan`'s composition that never included the indexed
pass — so `insert(out) { dir: rows[h].dir }` reached Zig as literal
`rows[...]` source text, an undeclared identifier. The comment beside it even
claimed "the same rewrite the stored RHS gets." It was the same name, one
pass short.

What this instance adds:

- **The copy was a SUBSET of a named composition.** Earlier tells found
  duplicated logic that drifted; this one was a deliberately re-built
  `storeRefsAll` that silently selected fewer passes than the shared
  `lowerStoreExprs` already offered. A private re-implementation inside a
  transform is a lowering boundary nobody diffs.
- **Emit-parse agreement is a contract, not a coincidence.** The text
  rewriters and `ZigExprParser` are one pipeline in two halves: anything a
  rewriter emits, the parser must read. `(&col)[idx]` was the first emitted
  shape that broke it — an emission optimized for "looks like Zig" over
  "readable by our own pass."
- **The fix stayed in the emitter, not the parser.** Teaching `parseUnary`
  about `&` would have made the array parse — and still produced
  `mem.eql(u8, [N]u8, "lit")`, a type error one level deeper. The char
  column's canonical read form is the slice; emitting it at the source
  (ixrefs, matching prewrite and the qrow projection) fixed the compare,
  the `stored` coercion, and the insert seed in one move.

Pinned at 690_372: `rows[world.ph].dir == "ltr"` wraps eql at a `| row`
continuation and inside a `! query` arm, a `stored` write takes the read as
a value, and an `insert` seed stores it — `hits 1211` end to end.

## The reach gap can be TEMPORAL: the name does not exist yet when the guard runs

The same class once more, and this instance has no second lowering and no
second scanner to count — the boundary is a *moment*. A `! query { [id]h }`
request bind is minted at the generated sweep's handler call:
`{ .h = __koru_handle_of(__koru_si) }`. The arm's `when` guard runs in the
sweep loop *before* that call, so `when rows[h].v == 20` emitted a reference
to a binding that had not been created yet — `use of undeclared identifier`
at backend compile, the position naming nothing about the real gap.

The reach question this belief asks — "what does this check quantify over" —
here has a *time* axis: the name's availability is bounded by when the
capture is minted, not just by where it is written. `when` is a real consumer
position sitting between the row and the call, and every request binding
needed its capture expression inlined into the guard text to live there
(`store.qguard.kz` substitutes `__koru_handle_of(__koru_si)` for `[id]` and
the cursor cast for `[ordinal]` — the same expressions the handler args mint,
computed at the guard's own moment).

- **A binding's true scope includes WHEN.** "The arm sees `[id]h`" was true
  of the arm's body and false of its guard, and the two reads of "the arm"
  were never distinguished until a program put the name in the earlier
  position. Enumerate the moments a name is needed, not just the places.
- **The substitute, not the pipe.** The fix could not thread another handler
  input (the guard runs before there is a call to thread it through) — the
  only sound move was recomputing the capture's value at the guard's
  position. Where a name must be visible before the mechanism that mints it,
  the minted expression itself travels to the earlier site.

Pinned at 690_373: `[id]` and `[ordinal]` names read inside `when` on
`! query` and `! first`, including a nested indexed read of the guard's own
store — `n 1030` end to end.

## And the reach gap is SPATIAL the same way: the scan quantifies over items, never continuations

Found the same afternoon, in the sibling direction. The coordinator's site
scan — the pass that mints each `rule`/`preorder` site's qrow/qbody/qsweep
units — iterates `flatItems(program.items)`: top-level `.flow` items and
module trees. A `std/store:preorder(t)` inside a `for ! each` arm is not an
item; it is a continuation node. The site's transform fired on it fine —
`siteView` already hands a nested site a synthetic flow keyed on the holding
continuation's location — and then refused `unknown store`, because the
coordinator had never minted the unit the view names.

Same defect family, different axis: the earlier instances are a feature
present in one lowering and absent in its sibling; this one is a *site*
present to the transform dispatcher and absent to the registration scan —
the two halves of one handshake disagreeing about what counts as a site.
`store.qsites.kz` now mints the identical flow view on the coordinator side
(`ast_functional.collectInvSites` walks continuation trees, skipping
`is_transformed_subtree` grafts), so both halves quantify over the same set.

- **A handshake has two scanners, and both are the unit of work.** The
  dispatcher could see nested sites for as long as `siteView` has existed;
  the registration scan could not, and the gap held because the corpus had
  never nested a preorder — every authored `preorder`/`rule` sits at top
  level by habit, so the two scanners were never compared on a program that
  distinguishes them.
- **The view contract is the fix shape.** Where a consumer and a producer
  must name the same thing, mint the SAME synthetic — here siteView's flow
  on both sides — rather than a parallel structure that can drift again.

Pinned at 695_006: `preorder` inside a `for ! each` arm walks the tree in
DFS order twice — `n 1234` then `n 12341234` end to end.

## The column list was derived from the wrong SURFACE, and the codebase knew the difference

`store.cols.kz` carries the lesson in its own header: `storeFieldOrder`
answers "every SoA column" and `storeInsertOrder` answers "the insert
surface" — and they differ by exactly the `[tree]`-synthesized `parent`.
A comment there records that merging them once broke all five tree tests.
`store.query.kz` read the INSERT event's fields for `col_names` anyway —
the surface that excludes `parent` by ruling — so `s.parent` refused as an
unknown field on a `! query` row while `tree[h].parent` indexed cleanly.

That is this belief's scope tell wearing a new costume: the derivation was
not wrong *code*, it was the wrong *question* — it asked the insert surface
for the column set instead of asking the column set. The fix routes the
non-view path through `queryStoreCols` (store.qcols.kz), which appends
`parent` when the store is a tree. Pinned at 695_007: `when s.parent == -1`
selects the root, `tree[s.parent].v` follows the edge.

- **Name the surface the derivation answers.** "columns" is ambiguous —
  insert surface, projection surface, SoA layout are three different sets
  with overlapping names. A helper named for the surface it reads is the
  only honest spelling; `cols.kz` already has the vocabulary.
- **The same miss can recur in the next file over.** The correction existed
  (the merge that broke the tests was reverted); the KNOWLEDGE existed
  (the header comment). What did not exist was the derivation actually
  consulting the answer — knowledge that lives in a comment one file away
  from the call site guards nothing.

## And a KIND test on the shadow check let one spelling through

Same file family, same sitting: the rule-5 shadow check — "a nested arm that
rebinds the row name stops the outer rewrite" — guarded on `node_is_sweep`
plus a `c.binding` read. A destructure arm `! query { [row]s }` has no
`binding`; its names live in `c.destructure`. So the one shadow spelling the
check could not see is exactly the one the request-block dialect introduced —
`[row]s` rebinds `s` identically to `! query s`, and the guard's kind test
let it pass straight through to the outer row's projection.

- **Read the guard against the rule, not the spelling.** "A nested arm
  rebinds the name" quantifies over *bindings*, full stop — `binding`,
  every destructure field, every arm kind. The check quantified over the
  spelling the author happened to write, which is the discriminant tell
  again: same function, same block, one arm walled and the sibling arm
  fallen through.
- Pinned at 690_374: an inner `! query { [row]s }` on the same store
  shadows the outer `s`; its `when` reads the inner row, and the outer
  row's own fields keep rewriting beside it.

## And the reach fix ran past the boundary the UNREACHED half was holding (2026-10-18)

The spatial reach fix — mint coordinator units for `preorder` sites nested
inside arm bodies — quantified over `rule` too, and `rule` nested in a body
is not a missed site, it is the REFUSAL. `std/store:rule` is a standing-rule
installation, top-level-only by construction (frag-store-verb-placement), and
the enforcement IS the coordinator's blindness: the site transform finds the
store declared but no minted sweep unit and teaches "top-level-only". Mint
the unit and the refusal never fires — 690_066 passed-compile on the board.

Same family, inverted direction: the previous instances asked "why did the
fix not reach this position"; this one asked, too late, "what was the
unreached position HOLDING". Discovery reach and refusal semantics are one
surface — a scan widened for the momentary verb silently legalized the
installation verb beside it.

- **Before widening a scan, enumerate what invisibility enforces.** The
  predicate `isQSiteInv` matched two verbs because they share a unit shape;
  they do not share a placement ruling. The corrected predicate names
  `preorder` only, and the comment now says the invisibility is load-bearing
  so the next widening has to argue against it, not stumble over it.
- **The board caught what the focused slice missed.** 690_066 was never in
  the iteration set — the pins for the fix (695_006, green) and the pin for
  the boundary it broke (a MUST_ERROR two directories over) live in the same
  scan's blast radius. A "focused slice" sized to the feature under test is
  sized to miss exactly this failure class.

## And the capture oracle read the AST the transform had already eaten (2026-10-18)

The `Handlers_*` capture set — the names a lifted member fn aliases from its
enclosing scope — was computed by walking the arm's continuation tree. But a
store site inside the arm gets its body consumed by the site transform and
replaced with an `is_transformed_subtree` graft; the ambient names that graft
references live only in the GENERATED call args (`.{ .w = w, .h = h }`) the
sweepbody invocation emits. `spec_sel.k`'s `| win w` binding was spelled
nowhere else — `h` survived via a surface-level `layout(cl: h)`, `w` did
not — so the Caps factory minted `T_h` and the emitted member fn died on
`use of undeclared identifier w`. Same family, same tell: the pass computing
a boundary's inputs asked a representation that had already lost them.

- **When the oracle and the boundary disagree about WHAT is the subject,
  the boundary wins.** The capture set is not "names the authored AST
  references" — it is "names the emitted code references that are live at
  the call site." collectEmittedCaptures now emits each arm block into a
  throwaway buffer (deferred decls routed to a scratch emitter, dropped)
  and scans the text; the AST keeps only the half it still owns — names
  bound INSIDE the arm, so a rebind `const w = …` in the arm itself keeps
  `w` out of its own prelude.
- **A fix to the oracle moves the whole interface.** The scan pass must
  see the same scope shape the real pass sees — same shared-param push,
  same eligibility filter — or it collects captures under a different
  contract and the two passes mint different sets (400_209's `r` tripling
  was a `seen` key dangling into a freed scan buffer, not a logic error —
  the arena was fine, the hash key was not).
- Pinned at 230_010: `| done w` referenced only inside a `std/store:query`
  arm body still reaches the member-fn handler; three `! tick` arms force
  the lowered path; un-falsified by a stash revert (backend-exec red on
  the old collector, green on the new).

## Sixth instance — the member list is enumerated once per WALK, and the pin sat on the quiet sibling (2026-10-21)

The sixth tell says the whole-program walk is an enumerated member list
whose prongs arrive one per incident. It undersells the shape: there is not
one list, there is **one list per walk**, and the store alone has two —
`Rewrite.rewriteNode` for the identity path, `storeRefsContH` for the
plural path — each accumulating the same positions independently. The
`.expression` prong (a produce arm `| then -> s[h].f`) landed in the
identity walk at 110_022. Fourteen months later the plural walk still
carried `.invocation`, `.inline_code`, and `.branch_constructor` — which it
had received at *its* incident, 690_256 — and nothing else. The two
enumerations were each "complete" and they disagreed by exactly one arm.

The corpus's green was honest and the gap was still invisible — the file's
own cross-product section, fired verbatim: `690_078` pins a read in a
produce arm and passed the whole time, because its store is a singleton.
The plural store — the common one, the one with `capacity:` — had no pin in
that position, and "produce arms work" was what the board reported.

The instance also crossed a construct boundary for the first time. `grid`'s
`lowerCont` carries the same switch for the same reason — `g[i].v` in a
produce arm went to the host verbatim on exactly the same axis. Two
different stdlib constructs, two walk functions, one missing prong each —
the language-limitation misreading served twice in one probe: the LangArena
binarytrees port compiled `| then -> arena[i].item + 1` and got
`use of undeclared identifier 'arena'` out of Zig.

- **When a member list has a sibling, the incident fix is a candidate for
  transplant, not a done fix.** 690_256's `.branch_constructor` prong went
  into the plural walk alone; nobody diffed the identity walk's list
  against it. The cheap question at any member-list fix is "which other
  switch over the same node kinds exists, and does it carry this prong" —
  one grep for `=> {}` siblings, or for the prong's name.
- **A green pin on the uncommon path reads as coverage of the common one.**
  690_078's store has no `capacity:`, so it exercises the identity walk —
  the rarer path in real programs. The pin taught "produce arms are
  covered" while meaning "produce arms are covered on the walk this author
  happened to declare."

Pinned at 690_376 (plural store: `| then -> arena[h].item + 1` inside a
tor called from a `| row` arm) and 697_017 (grid twin, same position).
294/295 on the 690+695+697 slice; the one red is a ledger-known prior
regression.

## Seventh instance — the context parameter, not a check, is what drifted (2026-10-31)

Every earlier instance is a *check* or a *member list* present on one
walk and absent on its sibling. This one is a **threaded parameter**:
`emitContinuationBody`/`emitContinuationList` update
`ctx.current_source_event` from each step's invocation as the chain
descends (the per-level scrutinee event — built for tap matching). The
`emitSubflowContinuationsWithDepth` return-switch fast path lowers the
same switches and never learned it — `source_event_name` is forwarded
unchanged into every nested level, so each nested switch's
payload-capture check asked "does `<head-event>.<arm>` have fields?"
against the *outermost* union.

An external user's 20-line probe made it visible: `u1.same` payload-free,
`u2.same` carrying a string, the `u2` match nested inside `u1`'s `same`
arm — `| same g` emitted `.same => {` with no `|g|` capture and the arm
body referenced an undeclared `g`. `.other` survived only because `u1`
has no `other` arm and the not-found default is "has payload" — the
conservative default masking the same bug on every arm the ancestor
doesn't happen to share.

- **A stale parameter drifts the same way a missing check does.** Both
  lowerings computed "does this arm carry a payload" correctly *per se*;
  the fast path asked the question about the wrong event because the
  name it consulted was never rebound at depth. The sibling's fix shape —
  rebind the scrutinee at each descent — transplanted verbatim.
- **The mask was the default.** `return true` on not-found is the right
  conservative choice for a lookup that may not see the module — and it
  also means the bug only fires when the ancestor union *has* the arm
  and *differs* on payload-ness. Every earlier program either never
  nested a switch or never collided names; the corpus's green was honest
  and silent on exactly the distinguishing shape.

Pinned at 400_229: nested unions sharing `same`/`other` arm names across
`u1`→`u2`, `| same g |> free(content: g)` — `use of undeclared
identifier 'g'` before, `ok` printed after.
