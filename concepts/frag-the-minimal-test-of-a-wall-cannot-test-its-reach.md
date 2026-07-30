---
type: belief
id: frag-the-minimal-test-of-a-wall-cannot-test-its-reach
provenance: KORU022 found to fire at a flow head and nowhere else; the third check this year whose reach stopped short of its own guarantee
ts: 2026-07-26
---

# The smallest test of a wall is structurally the one case that cannot test its reach (belief)

When a wall is built, the natural pin is the smallest program that trips it. The
smallest program is a one-line flow. **A one-line flow is a head** — so the
minimal, obvious, correct-looking test exercises the only position where reach
does not matter. The wall is then verified precisely where verification is
cheapest and proves least, and its behaviour one position further along is
untested by construction rather than by oversight.

This is not a lapse in any individual pin. It is what writing a minimal test
*does*, and it means head-only reach is the default outcome for every check
unless someone deliberately spends a second pin on the chained position.

KORU022 is the clean instance. Its guarantee — a branching tor's branches must
be handled — holds at a flow head and evaporates for every invocation after the
first in the same chain. Downstream, the illegal bind it exists to reject
compiles, takes the whole branch union under a name, and escapes into emission,
where the author meets a Zig standard-library formatting error instead. The
check is correct. Its reach is one invocation long.

## Why it stays hidden

A wall with head-only reach looks *more* trustworthy than an unbuilt one,
because its own test is green and its diagnostic is well-worded. Nothing
distinguishes "this wall works" from "this wall works at position one" without
a test that was never the obvious one to write.

It also disguises its own failures. Programs that slip past do not fail at the
wall — they fail much later, in emission or in host code, wearing a diagnostic
from a subsystem that has nothing to do with the mistake. Two red tests in
unrelated areas turned out to be this single hole seen through two spellings,
which is the tell: when unrelated findings rhyme, suspect reach before
suspecting a coincidence of bugs. Same reflex as
[[frag-a-pin-constrains-text-not-location]], different axis — there the
instrument could not express the constraint, here it expresses it in exactly
one position.

## What follows

- **Every wall wants two pins**: the head case, and the same violation moved
  down the chain. The second is the one that tests the guarantee; the first
  only tests that the sentence exists.
- **When a Koru mistake surfaces as a host-language error, suspect reach first.**
  A well-built wall reached and refused; a wall that was never reached lets the
  program run on until something further down chokes on it. The Zig error is
  the symptom of a check that did not fire, not of a check that is wrong.
- Any check whose only coverage is a one-line flow should be read as
  unmeasured past position one until a chained pin says otherwise.

## KORU047: the same axis, no pin at all, and no crash (2026-07-30)

A second positional instance, found from outside by Lars deleting an
implementation from a doodle. `KORU047` — "event X is invoked but has no
implementation" — fires at a flow head and nowhere after it. Declared, invoked,
unimplemented, one position down the chain: compiles, links, runs, exit 0.

Two things make it worse than the KORU022 instance above.

**It had no pin anywhere.** Not a head pin, not a chained one — `KORU047` appeared
in no test in the suite while its guarantee was being relied on. The rule stated
here ("read a check whose only coverage is a one-line flow as unmeasured past
position one") assumed a head pin exists to be misread. Zero coverage is the
weaker starting point and is invisible to the same reasoning, because there is no
green test whose narrowness you could notice. `510_115` is now the head pin, and
it went green on the first run — which is the whole problem in miniature: it
proves the sentence exists, and nothing else.

**Its escape does not fail.** Every earlier instance in this belief ends in a
crash somewhere unhelpful — Zig's formatter, a synthesised union, malformed
emission. That is bad diagnostics but it is still a stop. This one silently stubs
the missing event to zero-defaults and hands the result downstream: `-> string`
yields `""`, `-> i64` yields `0`. An arithmetic pipeline can lose an entire stage
and report a plausible number, at exit 0. Pinned by `510_116` (does not fire) and
`510_117` (what it produces instead).

So the practical tell in *What follows* needs its companion clause. "When a Koru
mistake surfaces as a host-language error, suspect reach" is sound but incomplete:
it trains attention on crashes, and the more dangerous outcome of an unreached
wall is a clean run. **A program that runs green and returns a suspiciously plain
value — empty string, zero, default-everything — is the same symptom with the
crash removed.**

**And read a diagnostic's text as a specification, not a description.** KORU047's
message names the exact hazard it fails to prevent: "without one the compiler
would silently stub it to return zero-defaults." That sentence is a testable claim
about the whole language, not about position one. Where a wall states what it
prevents, the statement is the spec and the wall is one implementation of it —
test the sentence.

This also sharpens the *Open* question below. The proposed lint stalls on deciding
which walls are legitimately head-only, but that judgement is not needed for the
strictly weaker rule: **a diagnostic with ZERO pins is a defect regardless of
which positions it ought to cover.** That fires on no legitimate head-only wall,
needs no taxonomy, and would have caught this one.

## Reach is not only positional

Position is the obvious axis and not the only one. A check can also cover one
*syntactic form* of the thing it is named for and no other, which hides even
better because no amount of moving the fault along a chain reveals it.

KORU100 is the instance. It is called "unused binding" and it reports one:
`| arm x |> …` with a dead `x` is caught. A chain bind — `(): x |>` — is never
use-checked, at a head or anywhere after it, so the diagnostic's name promises
the concept while its implementation covers one spelling of it. Ruled closed by
Lars 2026-07-26; pinned by `510_110` and `510_111`.

The reflex generalises: read a diagnostic's *name* as a claim, and ask which
forms of that claim are actually tested. A wall whose pins all use one spelling
is unmeasured for the others, exactly as a wall whose pins are all one-line
flows is unmeasured past position one.

There is a real limit on this one. A chain bind is not dead the way an arm
binding is — obligation enforcement keys off its presence, and stripping "dead"
binds is what once switched that enforcement off wholesale
([[frag-obligation-enforcement-keys-off-return-binding]]). So the rule has to
yield to KORU030 wherever the bind carries an obligation, whose message names the
resource and its disposer and is strictly the better sentence. Widening a check
to match its name is not the same as widening it everywhere.

## How this one survived: the rule was implemented twice

Closing KORU022's reach turned up the mechanism that kept the gap invisible.
The head position was never covered by the coverage checker at all — it was
covered by a *second, independent* implementation of the same rule living in the
auto-discharge inserter. So the head worked, the checker's own reach was never
exercised at the only position anyone tested, and the two halves drifted far
enough apart to word the same error code differently: the inserter says "branch
'x' must be handled but no continuation found", the checker says "required
branch 'x' not handled — event 'e' requires this branch".

The pattern to take from it: **a rule with two implementations has two reaches**,
and the more prominent one masks whatever the other cannot do. Duplicate
implementations do not merely risk drift in wording — they hide coverage gaps by
answering for each other in exactly the cases anyone thinks to check. Finding one
error code with two sentences is good evidence you are looking at this.

## The form axis is not a lesson you learn once

Within an hour of this belief being written down, the fix that closed KORU022's
reach committed the identical fault one level up: the new chain walk tested
`node == .invocation`, and a *labelled* invocation — the `#loop` fold head — is
`.label_with_invocation`. One spelling covered, the other silently skipped, in
the very code written to stop exactly that. It surfaced only because a prediction
made from the fix failed.

The same shape appeared a third time the same day in the emitter: a bare return
in continuation position is an `.expression`, while the `is_bare_return` flag
lives on `branch_constructor` — the implementation-side spelling. Two different
node kinds wearing one syntax, and the use-check handled only the one its author
had in mind.

So the form axis is not a mistake made by inattentive code. It is what happens
whenever a check enumerates node kinds by hand, which is most of them. Knowing
about it does not protect you; the enumeration still has to be checked against
the grammar rather than against what the author pictures the syntax being. The
practical tell is cheap: when a fix is written, predict a case it should now
catch and go run it. The prediction failing is how both of these were found.

## Open

Whether this is enforceable rather than remembered. A lint that flags a
diagnostic whose entire pin set is single-invocation flows would catch the
class mechanically, and is cheap — but it would fire on walls that genuinely
only apply at a head (declaration-position rules, module-level gates), and a
lint that cries wolf gets suppressed. Unsettled which walls are legitimately
head-only, and that question has to be answered before the lint is worth
building.
