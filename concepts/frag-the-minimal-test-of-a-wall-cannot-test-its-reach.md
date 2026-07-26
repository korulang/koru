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

## Open

Whether this is enforceable rather than remembered. A lint that flags a
diagnostic whose entire pin set is single-invocation flows would catch the
class mechanically, and is cheap — but it would fire on walls that genuinely
only apply at a head (declaration-position rules, module-level gates), and a
lint that cries wolf gets suppressed. Unsettled which walls are legitimately
head-only, and that question has to be answered before the lint is worth
building.
