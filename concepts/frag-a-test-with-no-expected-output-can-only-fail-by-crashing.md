---
type: belief
id: frag-a-test-with-no-expected-output-can-only-fail-by-crashing
provenance: surfaced when fixing the abstract-tor pairing bug turned 030_016 from green to red; the pre-fix emitted program was 104 lines containing no `process` event at all, and neither of the test's own prints ever ran — yet it passed (2026-08-10)
ts: 2026-08-10
---

# A test with no expected output measures liveness, not behaviour (belief)

`MUST_RUN` with an `expected.txt` asserts *what the program did*. `MUST_RUN`
without one asserts only *that the binary exited 0*. Those are different
assertions, and the second one is nearly free to satisfy: **an empty program
passes it.**

That is not a hypothetical. `030_016` exists to pin that array literals survive
inside a subflow implementation — its own comment says so, and its body prints
`PASS: subflow array literal works` when the thing works. It was green for as
long as anyone had looked. The emitted program was 104 lines and contained no
`process` event at all: the abstract tor's sole implementation had been renamed
out from under it by the pairing pass, so the entire subject of the test was
deleted before emission. Neither print ever ran. The harness had nothing to
compare, so it reported success.

**The failure mode is specific and it is the dangerous direction: a bug that
makes a program do *less* is invisible to a test that only checks the program
survives.** Crashes are caught. Silence is not. And silence is exactly what a
dropped implementation, a dead-stripped branch, or an over-eager fold produces —
so the tests most likely to be built around these features are the ones least
able to see them fail.

This also inverts how such a green should be read. Discovering that a fix turns
one of these tests red is *not* evidence the fix broke something; the prior green
was never evidence of anything. The question to ask is "did this test ever
execute its own subject?", and the cheap way to answer it is to look at the
emitted program for the symbol the test is named after. If the symbol is absent,
the green was measuring liveness.

Measured 2026-08-10: **110 of 1116** `MUST_RUN` tests carry no `expected.txt`.
Each is a place where a silent regression can pass. The number is the finding —
not that any particular one is wrong, but that a tenth of the positive board
cannot distinguish "worked" from "did nothing".

The remedy is per-test and not mechanical: an expectation invented without
running the working program is its own lie, and would produce a red that means
nothing. See [[frag-a-check-that-cannot-match-reports-clean]] — the same shape
one level up, where the guard exists but cannot fire.
