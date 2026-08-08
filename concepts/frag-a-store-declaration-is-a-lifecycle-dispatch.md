---
type: belief
id: frag-a-store-declaration-is-a-lifecycle-dispatch
provenance: probed while designing a pump aggregator — asked what a store says about an arm outside its vocabulary
ts: 2026-08-01
---

# A store declaration is a general lifecycle dispatch, not a `! discharge` slot (belief)

`! discharge` reads like a bespoke escape hatch bolted onto `std/store:new` for
the one case the auto-discharger cannot settle. It is not. The declaration site
is an interceptor dispatch over a **vocabulary** — `discharge`, `inserted`,
`removed`, `updated` — and a name outside it is refused with a message that
prints the vocabulary back to the author. So the site is designed to grow: the
cost of a new lifecycle arm is a name in an existing dispatch plus its emitter,
not a new declaration form and not a parser change.

This is the update that matters for anything wanting to hook a store's rows.
A pump arm — "here is how a row ADVANCES", the sibling of "here is how a row
ENDS" — has been reading as new language surface. It is a fifth interceptor.

The corollary is the trap, and it is not the one it first looks like. An
interceptor's body is **silent**: an arm whose body is a single `std/io:print.ln`
compiles, runs, prints nothing, and reports nothing. The first reading — "the
arm never fires" — is wrong. It fires; the store calls the handler, and the
handler is emitted. What does not happen is the body's **comptime transform**:
`print.ln` is `~[keyword|comptime|transform]`, a call site rewritten into inline
Zig, and inside such a body it survives unexpanded as a call carrying the raw
template string, whose result is discarded.

And the arms **disagree with each other**, which is the finding. `! discharge`
expands its body, interpolation and all; `! inserted` and `! removed`, on the
same declaration, do not. So this is not "synthesized bodies don't normalize" as
a flat rule — the declaration site already knows how to run an arm body, and two
of its arms don't get it. 690_236 pins the asymmetry, control in the same file.

The two paths differ in how the body is appended. `! discharge` rides the
teardown flow as an ordinary flow item with no `impl_of`. The lifecycle arms go
through a shared emitter that appends a `retain`ed event declaration plus a flow
that IS its implementation — `impl_of` set.

The cause, once instrumented, is none of the four things it looked like. It is
**two slots for one fact**.

An expansion produced by a transform is stored on the invocation
(`Invocation.inline_body`). The emitter reads it from *two different places*
depending on position: a flow ROOT is emitted from `Flow.inline_body`, a nested
continuation from the invocation's own slot. The runner already knows this and
migrates between them when it grafts a flow into a nested site. The store's arm
emitter did the same rebuild in the opposite direction and did not migrate — so
a body whose root had already expanded arrived with the code on the invocation
and the flow slot empty, and fell between the two readers.

The depth-first walk is why it is the ROOT that suffers. An arm body's own
transforms fire before the declaration around them does, so by the time the
store rebuilds the body, the root has already been rewritten. Nested positions
were never at risk; they are read from the slot the transform actually wrote.

That also explains the sibling behaviour that made the earlier readings look
sound. `! discharge` clones its continuation whole and never rebuilds a root, so
it never lost anything. A transform whose output is an ordinary invocation
rather than an expansion had nothing in the slot to lose. Neither is a different
rule — both are the same rule, not exercised.

Why nobody found it: **no green test puts an expanding transform at an
interceptor arm's root.** The green interceptor tests root their arms elsewhere
and chain the expanding call behind. Uncovered, not contested.

The method note is worth more than the bug. The scope shrank four times under
measurement — the interceptor class, then inserted-not-discharge, then
some-transforms-not-others, then Expression-in-root-position — and every one of
those would have bought a different and wrong patch. None of them survived
instrumentation. Reading produced four plausible stories; one print statement in
the walker ended it. When a defect's scope keeps moving, the scope is a guess,
and the instrument is cheaper than the next hour of reading.

So this stays adjacent to **authored surface is normalized, synthesized surface
never is** without collapsing into it — that shape predicts far more failure
than is observed. What it is: the first place where a store declaration accepts
surface it silently does not run, and the pin for it (690_236) carries a control
that passes in the same file.

So the standing open question — should transform output re-enter normalization?
— now has a case that answers it. A lifecycle arm is authored surface by every
measure the author can see: they wrote it, at a declaration, in Koru. If the
body a user writes cannot run the transforms that same body runs one line
higher, the declaration site is offering surface it cannot honour.

This is load-bearing beyond the four names. Any future interceptor — a pump's
"how a row ADVANCES", the sibling of "how a row ENDS" — is born into the same
lowering, and would be born silent. The vocabulary cannot safely grow until the
bodies run.

Open question: the vocabulary is closed and the refusal calls the rest "a later
slice", so the design anticipates growth without saying what governs it. Nothing
states which lifecycle moments a store owes an arm for, so each addition is
argued on its own. A rule — every transition a row can make is nameable, or
these four are the transitions and the list is complete — has never been
written down.

## The rebuild is a dispatch on the body's shape, not one repair

Merging this lane against the threading lane put a second fix on the same
block, and the two turn out to be halves of one thing rather than rivals.

Above, the arm body is assumed to still be an **invocation** — a head the
emitter can root a flow at — and the repair is to carry its expansion up so the
flow-root reader can see it. That assumption does not always hold. A nested
store-read (query, rule, sweep) sitting inside the arm splices its whole loop
into the body during the same depth-first walk, and what the rebuild then finds
is not an invocation at all but raw `.inline_code`. There is no head to root a
flow at, so the carry-up has nothing to carry and the flow path has nothing to
build from. That body has to become a **proc** impl instead — a proc binds every
event input as a const, which is exactly how the spliced loop's captures resolve
back to the interceptor payload fields. 690_093 pins that shape; 690_240 pins
the invocation shape.

So the belief above is narrower than it read: the arm rebuild is not "migrate
between two slots", it is a dispatch on what the depth-first walk left behind.
Two outcomes, two lowerings, and the choice between them is forced by the body's
node kind. That the same walk causes both — the transform that expands a root,
and the store-read that replaces one — is why they landed on one block from two
lanes on the same day.

This sharpens the load-bearing claim rather than softening it. A fifth
interceptor is still born into this lowering; it is now born into a lowering
with a branch, and a new arm has to be correct on both sides of it.

## Evolved 2026-08-08: the site grows in TWO dimensions, and the second one was free

The belief above says the declaration site is designed to grow, and prices that
growth in *new arm names*. That is one axis. There is a second, and it went
unnoticed because nothing had asked for it: what an arm ALREADY THERE can ask
the site to hand it.

A query, rule or preorder arm has a **request block** — `{ [row]e, [id]h,
[ordinal]n }`, synthesized only where named (690_246, 690_247, 695_005). The
lifecycle arms never got one. They parsed their braces as columns and never
looked at annotations, so `! inserted { [id]h }` was refused with *"payload
field 'h' is not a field of store 'rows'"* — a diagnostic about columns, for
something never meant to be one. The two forms were exactly inverted: on a rule
an *unannotated* entry is refused, on a lifecycle arm an *annotated* one was.

The consequence was not a missing convenience. It was that **an observer
outside the store had nothing stable to key on.** A lifecycle arm could name
only the row's columns, which are data and may repeat, so anything minting a
thing per row — an element, a handle, an index entry — had to re-derive the
correspondence later by searching. Measured in the DOM gauntlet: 92% of a
thousand-row clear, 71.6 ms of 77.8, was that search. The store's own per-row
removal machinery was 2 ms of it.

So the correction to the price above: growth along this axis cost **no new
spelling and no parser change** — the annotations already parsed, and `[id]`
already meant "this row's handle" everywhere else. It cost a branch where the
block is read and an expression where the payload is built. The vocabulary was
not missing; its *reach* was short, and nothing in the design said where it was
supposed to stop.

Which sharpens the open question this file ends on. It asks what governs the
growth of arm NAMES. The same gap exists one level down and is easier to state:
**a request is meaningful wherever the site can synthesize it**, and the site
knew the row's identity at both ends all along — `__koru_new_row` sits in scope
at the insert payload site, unused, and removal arms fire before the swap and
the generation bump precisely so the dying row still resolves. Nothing decided
those arms should not offer it; no one had needed it.

The general shape, and the reason this is worth a paragraph rather than a
changelog line: **when a facility exists in one position and not another, the
absence is usually not a ruling.** It is the shape of what was asked for first.
The tell is the diagnostic — a refusal that talks about the wrong thing
entirely (`'h' is not a field`) means the code never modelled the request as a
possibility, rather than having considered and rejected it. A refusal that
names what it refuses is a decision; one that misfiles the question is a gap.

## Evolved 2026-08-08b: a removal VERB is only worth adding with its own ARM

The section above priced growth along two axes — new arm names, and what an
existing arm can ask for. `clear` is the first case where the two are not
separable, and it sharpens what a lifecycle arm is FOR.

The obvious reading of a bulk-removal verb is store-side: emptying a thousand
rows one at a time must be doing redundant work, so give it a fast path. That
reading is wrong by an order of magnitude. Measured in the DOM gauntlet, the
store's own per-row removal — the sweep, a thousand `take`s, the handle
bookkeeping — is **2 ms of a 78 ms gap**. Substantially all of the rest is the
OBSERVER: `! removed` firing a thousand times, each firing going off to find
the thing it had once been handed.

So the verb is not the optimisation. **The arm is.** `std/store:clear` without
`! cleared` would empty the store faster and change nothing that mattered,
because the observer would still be paying per row — or, worse, would be
silently skipped and stop being told at all. That is why `clear` REFUSES a
store carrying a `! removed` arm and no `! cleared` arm rather than doing the
defensible-looking thing.

Which gives a rule for the next verb that removes rows, and there will be one:
**a removal verb and its arm are one unit of design.** Adding the verb alone
produces something that looks like a speedup, benchmarks as a speedup on a
store nobody observes, and does nothing for the case that motivated it.

The corollary is about what an aggregate arm can carry, and it is a constraint
rather than a shortcoming. `! cleared` binds a COUNT and nothing else, because
it fires after the store is empty and no row survives to read. An arm that
could still see rows would be describing a half-done operation. Past-tense
name, past-tense payload.

One implementation fact worth keeping next to the belief, because it is the
kind of thing that reads as correct and is not: invalidating outstanding
handles across a bulk removal is NOT a brand bump. The brand is a compile-time
constant naming WHICH STORE issued a handle; bumping it breaks cross-store
discrimination and invalidates nothing. The per-slot generation is the mutable
identity, so a clear bumps every live slot's generation — one pass over a small
array, which is affordable precisely because it is the part that was never
expensive.
