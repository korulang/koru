---
type: belief
id: frag-an-exemption-inherits-the-credibility-of-the-test-that-justified-it
provenance: surfaced removing the `[abstract]` exemption from the emitter's loud-hole guard; the exemption's own comment named 030_016 as the program it protected, and 030_016 turned out to be reaching the guard only because its implementation had been renamed away by a separate bug (2026-08-11)
ts: 2026-08-11
---

# A carve-out is only as true as the test that made it necessary (belief)

A guard gets written broad. A test goes red. The guard gets narrowed until the
test is green again, and the narrowing gets a comment explaining why that case
is legitimately different. This is normal, careful work, and the comment is
usually written in good faith by someone who looked.

**The failure is that the exemption then outlives any check on the claim
underneath it.** The comment says "this case is different"; what was actually
observed was "this test went red". Those are the same sentence only if the test
was measuring what its name says.

Concretely: the emitter refuses to invent an answer for an event nothing
implements — it emits a panic naming the event instead of a zero-valued
placeholder. `[abstract]` events were exempt, and the exemption carried a
specific, plausible justification in the source: an abstract event's body is a
dispatch stub that is genuinely on the call path, one test calls such a stub
during comptime evaluation, and panicking there would kill a working program.

Every clause of that is reasonable. It was also wrong, and the way it was wrong
is the point: the named test reached the guard because it had **no
implementation left** — a different pass was renaming its only implementation
out from under it. The exemption was not protecting a legitimate dispatch stub.
It was protecting a bug from being noticed, and it did that job for as long as
it existed. Fix the renaming, and the test never reaches the guard at all;
`found_impl` is true and the question does not arise.

**The tell is a carve-out whose justification is a single named test.** One test
is an anecdote about one program, and the exemption generalises it to every
program with that annotation. When the comment says "X is exempt because
`NNN_NNN` does Y", the load-bearing claim is not "X is different" — it is "Y is
what `NNN_NNN` actually does", and that is checkable. Go check it: read the
emitted program, not the test's pass/fail.

So, before narrowing a guard to make a test pass: **verify the test does what it
claims, then narrow.** And when inheriting an existing exemption, treat the
named test as a citation to follow rather than a settled matter — the citation
is the only evidence the exemption has, and a citation to
[[frag-a-test-with-no-expected-output-can-only-fail-by-crashing]] is no evidence
at all.

This is the same shape as [[frag-a-correctness-argument-in-a-comment-gets-reverted]]
seen from the other side: there, prose about why code is right decays away from
the code; here, prose about why a rule is narrowed decays away from the reason.
Both are load-bearing claims parked where nothing executes them.
