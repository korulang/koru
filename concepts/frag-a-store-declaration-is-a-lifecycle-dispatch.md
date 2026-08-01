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
