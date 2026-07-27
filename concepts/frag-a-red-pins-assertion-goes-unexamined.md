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

## Not an argument against red pins

Pinning a bug as a failing test first is correct and stays. The discipline this
adds is one question at triage rather than at authoring time: before fixing a
red test, state what it claims and check that the claim is still ruled. A fix
that makes a wrong assertion pass is worse than the red — it converts an
unexamined claim into an enforced one.
