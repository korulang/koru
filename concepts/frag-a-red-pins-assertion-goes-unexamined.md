---
type: belief
id: frag-a-red-pins-assertion-goes-unexamined
provenance: 210_174 asserted the wrong thing for months; ruled and split 2026-07-27
ts: 2026-07-27
---

# A red pin's ASSERTION goes unexamined, because being red explains it away (belief)

A `MUST_RUN` that fails states two things: *this program should run*, and *today
it does not*. Only the second is visible. The first is a claim, and a red test
is exactly the condition under which nobody checks it — the failure supplies a
ready explanation ("known gap"), so the claim underneath rides along unread.

`210_174` carried `MUST_RUN` and expected `lo 7`, asserting that arms at column 0
attach to an indented chain step. It was red, so it read as a parser gap. The
assertion itself was wrong: those arms sit at the level of a step declaring no
branches, and a step either names its value or branches on it, never both. The
program should not run at all. Months of readings, including several this
session, took the shape as given and asked only why it failed.

**Second instance, same day.** `800_002_effect_branch_capture_shadow` was a
`MUST_ERROR` pinning Zig's `capture 'x' shadows function parameter`, and its
prose argued a ruling: that an effect payload and a capture nested inside its
own handler denote one value, that "Koru has no rule against it", and that the
emitter should alpha-rename. It was green — refused by the host — so the verdict
looked settled and the argument underneath went unread. Lars ruled the opposite
when it finally surfaced: that shape is real nesting, the outer binding is live
when the inner one binds, and Koru forbids shadowing. A GREEN test can carry an
unexamined claim too, when what makes it green is a host error rather than a
wall the language built.

`frag-a-red-pin-is-unfalsifiable-documentation` names the neighbouring hazard —
prose about a red test that nothing can contradict. This is the sharper one: the
*test itself* is the unfalsifiable documentation, because its expectation is
never exercised while it fails.

## The tell, and what to do about it

The tell is a red test whose failure has a *satisfying* explanation. Satisfaction
is the signal to stop and ask the other question: **is this what should happen?**
Cheapest form — read the test's expectation out loud as a claim about the
language, with the failure covered up. If it does not stand on its own, the pin
is the bug.

Where this bites hardest is a test that has been red long enough to become
furniture. A recently-written pin still carries its author's reasoning; an old
one carries only its assertion, and the assertion is the part nobody re-reads.

## Third instance, 2026-08-09 — the comment does the explaining away

`140_005` and `140_009` pinned a `.k` contract merging with its `.kz` companion.
Both were red, and both opened with a comment stating the cause: the loader
stops at the first extension its probe order reaches and never opens the
sibling. That was accurate the day it was written.

By this session the merge worked. The failure was a Zig type error *inside* the
proc body — the fixtures returned a branch constructor for a signature with a
bare return, a shape the corpus stopped using months ago. Reaching that error at
all proves the merge: an unmerged module fails as an unknown event, several
stages earlier.

The refinement this adds: **the danger is not only the unexamined assertion, it
is a comment that supplies a CAUSE.** A bare red invites the question "why?"; a
red with a stated cause answers it in advance, and the answer keeps being read
long after it stopped being true. Two capabilities were believed unbuilt because
their own pins said so, and the sentence outlived the defect it described. This
is why a test comment says what the test PINS and never why it fails today —
that rule is usually argued as tidiness, and it is not: a why-it-fails comment
is a claim about the compiler with no mechanism keeping it honest.

Corollary for triage: when a red test's stated cause names a mechanism, check
the mechanism before believing the sentence. Here the check was thirty seconds —
read which stage the error came from.

## Not an argument against red pins

Pinning a bug as a failing test first is correct and stays. The discipline this
adds is one question at triage rather than at authoring time: before fixing a
red test, state what it claims and check that the claim is still ruled. A fix
that makes a wrong assertion pass is worse than the red — it converts an
unexamined claim into an enforced one.
