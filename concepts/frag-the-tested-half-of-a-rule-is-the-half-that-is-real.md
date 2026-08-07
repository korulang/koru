---
type: belief
id: frag-the-tested-half-of-a-rule-is-the-half-that-is-real
provenance: 330_118 states a two-sided rule in its header and tests one side; the untested side turned out never to have been implemented, found 2026-08-07 by a Unikraft lift whose tor had the untested shape. Written after the same asymmetry showed up twice more the same day
ts: 2026-08-07
---

# The tested half of a rule is the half that is real

`330_118_conserving_tor_is_not_a_disposal_candidate` states a rule with two
sides. A tor that *conserves* an obligation — every arm hands back what it was
given — is not a disposal candidate. A tor that *converts* it "is a different
thing and stays a legitimate candidate."

The test exercises the first side. Its `step` conserves on every arm and is
correctly excluded, and it has been green for as long as it has existed.

The second side was never implemented. `eventReIssuesObligation` — which exists
twice, independently, in the checker and in the auto-discharge inserter — walks
every branch and returns *excluded* on the first arm that conserves, without
ever asking whether another arm converts. A tor that conserves on one arm and
converts on another is dropped from the candidate list entirely, and the caller
is told no tor accepts the state while calling the arm that accepts it. Pinned
red as 330_133.

**The comment reads exactly like a specification and enforces nothing.** It sits
inside a green test, in the file that is supposed to be ground truth, next to a
rule that *is* enforced — which is what makes it convincing. Anyone reading
330_118 to learn the rule learns both halves and has no way to tell that only
one of them is load-bearing.

So the general form: **prose in a test describes; only the assertion decides.**
Where a rule has cases, each case is real exactly to the extent some test takes
it. A two-sided rule with a one-sided test is a one-sided rule wearing a
two-sided description, and the undertested side will be wrong *by default*
rather than by accident — nothing was ever pushing it toward correct.

**The tell is countable and worth looking for deliberately: a test whose header
states more cases than its body exercises.** That gap is where implementations
drift, because there is no force on the unexercised side at all. It is not that
someone made a mistake; it is that nothing could have caught one.

And the corollary for writing rules down: when a rule has an exception, the
exception needs its own test *at the moment the rule gets one*, or the exception
is decoration. Stating both halves and testing one is worse than stating only
the half you tested — it manufactures confidence in the half that has none.

Related: [[frag-a-record-nothing-re-reads-becomes-a-fossil-that-gives-orders]]
— the sibling failure. There a record was true and went stale; here it was never
enforced at all. Both are claims nothing executes, and both read as authority.
