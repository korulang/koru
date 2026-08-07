# Koru

Koru is a compiler. The toolchain is the product.

**So this repo is where every defect found anywhere ends up.** When work in
`orisha`, `koru-libs`, an example, or a gauntlet hits a `koruc` bug, that work
stops and the fix lands *here*. A repro, a pin, or a report is not a fix — the
commit is. Never leave a consumer shaped around a compiler bug; the shape
outlives the memory of why it exists, and the bug ships.

**Start with the `koru-toolchain` skill** — how to compile, how to run the suite,
the four-stage metacircular pipeline, what bites you. `koruc <file> glance` gives
a declaration surface before reading a big file.

## Ground truth is the tests

What's legal and what's rejected lives in the suite, not in prose. A `MUST_ERROR`
test with its `expected_error` pins both the refused program and the diagnostic
refusing it. When this file and the compiler disagree, the compiler wins.

- **`koru-by-example.md`** — curated tour of real tests, verbatim source.
- **`tests/regression/`** — the full suite.

## Syntax is Lars's

Don't invent spellings — not a keyword, not an ambient name, not "just for now."
When work needs surface that doesn't exist, bring the question and the evidence.
Never synthesize Koru syntax from analogy; read a passing test or say it's a
guess.

This is about *spellings*. Everything else — what to build, what to fix, when to
push, what to publish — is ordinary work.

## The suite is expensive

~11 minutes for a full `--no-cache` board. While iterating, run the affected
tests plus controls:

    ./run_regression.sh <full_test_name> <full_test_name> ...

Filtered runs write no snapshot, so they can't clobber `latest.json`. The full
board is for publishing.

**Never `zig build`, or edit `koru_std/` *or* `src/`, while a suite is live.**
Each test's backend build compiles its emitted Zig against the **live** `src/`
tree, so a half-written file there turns into reds that name your own edit —
33 of them in one measured case, all reported as `backend`, none real.

**A board run from a worktree under-reports, and says nothing about it.** Tests
that reach outside the repo do it by *relative depth* — `350_013`'s `koru.json`
names `../../../../../../orisha/lib`, six levels up. From the main checkout that
lands on the real library; from `.claude/worktrees/<name>/` the same six levels
land somewhere that does not exist, and the test fails `frontend` with
`KORU002 module not found`. Measured 2026-08-08: **4 such tests**, one of which
was green on the main-tree baseline and looks exactly like a regression.

So before calling any worktree board's delta real: grep the failures for
`KORU002.*module not found` and subtract them. They are a property of *where you
ran*, not of what you changed.

**A filter that matches nothing is dropped in silence.** `./run_regression.sh
<real_name> <typo>` runs one test and prints `ALL TESTS PASSED`, exit 0. Zero
matches refuses (`f1a74bd1`); a *partial* match does not. So a control set
verifies only the names that happened to be spelled right — check the
`Running N tests` line against the number you asked for.

## Emit `for`, never `while` — it is measurable performance

**Any emitter that produces a counted Zig loop emits `for`, not `while`.** This
is not style. `while (i < len) : (i += 1)` hands the optimizer a mutable
induction variable and a loop-carried condition; `for (0..len) |i|` hands it a
known trip count, and `for (xs, ys) |*x, y|` additionally proves non-aliasing and
removes bounds checks. That is the difference between a vectorized loop and a
scalar one.

Measured 2026-07-31: a trivial two-store program emits **19 `while` against 5
`for`**, and `koru_std/store.kz` carries **34 `while` sites** — including the
sweep loop, the hottest loop the language has.

A `while` is correct only where the trip count genuinely is not known up front
(a parser scan, a freelist walk). If you can name the end before you start, it
is a `for`.

## Test comments

Write what the test *pins* — the shape it guards. Not its red/green state, not
why it fails today; that's derivable and goes stale the moment it flips.
