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

The belief this leaves us with, in its general form: **a harness must never
report a state it has not established.** A timeout is not a failure — `killed` /
`SIGTERM` is right there on the error object, and collapsing it into the failure
bucket destroys the one signal separating "your change broke this" from "our
budget was too small today." The cost is not a wrong number; it is a bisect
through innocent commits hunting a bug nobody committed.

The same rule caught two more instances immediately afterwards, which is why
this file is phrased generally rather than about timeouts:

- **Absent is not red.** `SUCCESS`/`FAILURE` markers are run *output*, not
  tracked files. Reading their absence in a fresh worktree as "the Zig baseline
  failed" reported 152 zig-red tests that had simply never been measured. Three
  states, not two — green, red, and *unknown* — and a tree with no markers gets
  told to run the suite rather than handed a fiction.
- **A documented guarantee is a claim, and can be false.** This harness's header
  asserted its results "predict what the runner would say". The real closer runs
  the JS check only when the Zig baseline already passed
  (`regression_lib.sh:277`); this one runs regardless, so the guarantee was
  false for 23 of 222 tests. A comment promising fidelity is not fidelity, and
  it is more dangerous than no comment, because it discourages the check.
  That guarantee turned out to be false a SECOND time, and worse. The closer
  runs the emitted program from the repo root (`regression_lib.sh:347`, and the
  Zig binary likewise at `:1462`); the harness ran it from the test directory.
  Every `ARGS` entry and hard-coded path in the corpus is repo-root-relative, so
  every filesystem and args test read `ENOENT` and reported a mismatch no matter
  how correct the emitter was — 1/26 measured against 16/26 under closer
  semantics, identical code, one word of difference. A contestant doing correct
  work would have reported an honest Frontier at a wall that did not exist, and
  it would have been believed, because a Frontier is exactly the outcome we
  reward for intellectual honesty.

  That is the sharp form of this failure: **a harness that diverges from what it
  claims to mirror does not produce noise, it produces credible false negatives
  in the one report shape designed to be trusted.** Two divergences found in one
  header; the difference is that the zig-red one is now declared and split in the
  report, while this one was simply wrong. Both were found by someone measuring
  rather than reading — the second by a contestant who mirrored the harness into
  `/tmp` to compare, rather than editing the instrument it was being scored by.

Splitting that last one made the honest figure *better* — 147/198 zig-green
instead of a blended 152/222 — worth recording because the reflex is to expect
honesty to cost something. Here the blend was hiding a real result behind 23
tests that were padding the denominator.

The wider pattern, and the reason this is worth a file: **this is the fourth
time — of seven so far — that this instrument produced a confident wrong answer
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
