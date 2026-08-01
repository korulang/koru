---
type: belief
id: frag-a-verdict-read-from-an-artifact-does-not-cover-the-run
provenance: 2026-08-01 — a MUST_RUN test whose binary printed the right output and then aborted 134 passed the suite; measured by removing its EXPECT_TRAP marker and watching the same binary flip to crash-134
ts: 2026-08-01
---

# A verdict read from an artifact grades the artifact, not the run that produced it (belief)

`regression_lib.sh` runs a `MUST_RUN` binary, captures its exit status, and then
decides the test by diffing `actual.txt`. The three expectation branches —
`expected.txt`, `expected_patterns.txt`, `EXPECT` assertions — never read the
status. Only the fallback for tests with *no* expectation did, and almost every
`MUST_RUN` test carries an expectation.

So a program that printed exactly the right bytes and then died got `✅ PASS`.
Not a near-miss: the double-free behind 690_195 printed `b x`, segfaulted, and
the harness wrote a SUCCESS marker.

## Why nothing surfaced it for so long

A segfault writes **nothing** to stdout or stderr. The failure's whole signature
is the exit code, and the exit code was the one thing not consulted. `actual.txt`
— the artifact a human opens to check the test, and the artifact every downstream
tool reads — is byte-identical whether the program exited cleanly or died on the
way out.

That is the general shape, and it is why this is not a bug about one `if`:

> An artifact records what a process **emitted**. It does not record how the
> process **ended**. A verdict computed only from the artifact is silent about
> every failure mode whose signature is not in the bytes.

The suite had a wall for this and the wall's own text shows the boundary.
`verdict:runtime` reads *"a non-zero exit with no expectation declared is a
failure."* Whoever wrote that was looking straight at the exit code. They guarded
the case where nothing else could speak, and where an expectation existed they
let the expectation speak alone — as if an output match subsumed the question.
It does not. The two grade different things.

## The rule cannot be "exit 0"

This is the part that makes it design work rather than a one-line fix. Four tests
in the corpus pass **because** they die: 690_115 and 690_116 (stale row handle,
write and read), 690_196 (foreign handle), and 837 (uncaught panic branch). All
four abort 134 by design, and their pinned message is printed by the panic
handler on the way down. A naive exit-0 requirement turns the corpus's best
refusal tests red.

So the verdict needs a distinction the harness did not have: a **pinned trap**
against an **unpinned crash**. The line is drawn by declaration — an
`EXPECT_TRAP` marker in the test dir — and deliberately not by inspection:

- **Not inferred from the message.** "The output contains `panic:`, so the death
  was intended" is the same move that opened the hole — reading intent out of
  bytes the program happened to emit. A crash can print anything, including the
  panic line of a trap it was supposed to reach by another route.
- **Declared, and therefore greppable.** `find tests -name EXPECT_TRAP` answers
  "which tests are allowed to die" exactly. No predicate over output can.

The marker takes the exit codes it pins, so a trap that *degrades* is still
caught: 690_115 pinning 134 fails if the abort becomes a segfault, even though a
segfault at that site would print the same panic line first.

## The obligation a declaration creates

A declared exception has to carry its own weight, or it becomes the next silent
green. Two conditions ride with `EXPECT_TRAP`:

- **A trap must pin the message it dies with.** Without it the test pins
  "something went wrong" and stays green through an unrelated death — the bare
  `MUST_ERROR` pathology in a different organ (see
  [[frag-a-misnamed-assertion-is-silently-no-assertion]]).
- **A trap that stops trapping must fail as that.** If the marker is present and
  the binary exits 0, the pinned refusal is gone; naming it
  `expect-trap-but-exited-clean` says so, where an output diff would only report
  a missing line.

Both are the same instinct: the exemption states what it expects, so the day it
stops being true, something says which thing stopped.

## What this suggests to look at next

The generalisation is not specific to exit codes. Wherever a verdict is computed
from a recorded artifact, ask what the process could do that the artifact cannot
show. Two live candidates, neither measured:

- The comptime gate reads `backend.out`/`backend.err` and is subject to the same
  question about Stage C's own exit.
- The JS equivalence path checks node's exit code (`regression_lib.sh:345`) and
  compares output — it got this right from the start, which is worth noting
  because it means the knowledge existed in the file the whole time. See
  [[frag-a-wall-guards-one-direction-of-a-symmetry]].

Related: [[frag-a-failure-that-looks-like-success-is-unfalsifiable]] is the same
family from the reporting side, and
[[frag-rejecting-a-program-and-crashing-share-one-exit-path]] is the compiler-side
instance — there, two intents collapse into one status; here, one status is never
read at all.

## Open

- No census exists of `MUST_RUN` tests that exit non-zero without a panic line —
  a clean `exit 1` is invisible to the stored-artifact scan that found the four
  traps. Only a full board under the new gate can enumerate them.
- Whether a trap should also be required to pin the *trap's own* message, rather
  than any output expectation, is unresolved. The current wall accepts a test
  that pins only its pre-trap output.
