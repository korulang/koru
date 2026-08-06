---
type: belief
id: frag-a-timeout-is-not-a-failure
provenance: js-scan reported 121/220 -> 92/222 after merging main; all 46 new "compile failures" were pinned at exactly 30s, a cold backend cache rather than any code change
ts: 2026-08-06
---

# A measuring harness must distinguish "it failed" from "we stopped it"

`js-scan` classified any non-zero exit from `koruc` as `js-compile`. That is
defensible until the process did not exit on its own — and then it is a lie
with a specific, expensive shape.

Merging `main` into the JS-parity integration branch invalidated the backend
build cache. Every test then performed a full metacircular rebuild instead of
reusing a cached backend, and under 8-way parallelism 46 of them crossed the
30-second per-test limit. The scan reported **121/220 → 92/222**, which reads
exactly like a code regression introduced by one of main's five new commits.
It was not. Re-running with a warm cache and a raised limit returned **121/222**
— and took 28 seconds instead of 550.

The tell was in the data the harness already had and was not using: the 46
failures had a duration `min 30005ms, median 30016ms, max 30117ms`. Nothing
that fails for a *reason* clusters inside 112 milliseconds of a round number.

The belief this leaves us with: **a harness must report the reason it stopped
watching as a distinct outcome from the reason a thing failed.** `killed` /
`SIGTERM` is available on the error object; collapsing it into the failure
bucket destroys the one signal that separates "your change broke this" from
"our budget was too small today." The cost of that conflation is not a wrong
number — it is a bisect through innocent commits looking for a bug that was
never committed.

The wider pattern, and the reason this is worth a file: **this is the fourth
time this instrument produced a confident wrong answer before producing a right
one.** Annotation-prefixed declarations were invisible to its regex and hid
`std/store` entirely; type references parsed as calls; fixture host code went
uncounted, overstating the testable population by 2.5×; and now a timeout wore
a compile error's clothes. Every one was caught by *running* the instrument and
disbelieving the first output — none by reasoning about it beforehand. A
measuring apparatus should be assumed to be lying until it has survived
contact with a result someone was motivated to check.

Open question: whether the per-test timeout should scale with observed cache
state at all, or whether the harness should simply warm the cache as an
explicit first phase and then hold a tight limit — a tight limit being useful
precisely because a genuine hang should still be caught quickly. The current
fix (a distinct `js-timeout` status plus a raisable limit) reports the
condition honestly but does not prevent it.
