---
challenge: wall-census
kind: frame
status: standing
yields: a census of the walls the suite has, the walls it needs, and one new wall built where the gap is widest
family: toolchain
---

*Walker context — the recurrence that earned this frame. Scoping the 2026-07-31
triage, two separate counts of "how many negative tests pin no diagnostic"
returned **171** and then **131**. Both were wrong. The true answer, using the
harness's own predicate, is **4 of 227**.*

*The reason the first counts were wrong is the finding: **a wall already exists**
that nobody remembered. `scripts/regression_lib.sh:608` fails any `MUST_ERROR`
test that pins no diagnostic, and it fails it as `config-error` so it shows up on
the board. It has been quietly holding the negative suite at 223/227.*

*That is the shape worth generalising. A doctrine written in `CLAUDE.md` decays.
A doctrine compiled into the harness does not — and it also stops being something
anyone has to remember. **This frame asks which of our written rules are walls,
and which are still just prose.***

---

## The brief (sealed — you are the contestant)

Produce the **census**: every rule this project holds about test quality, and for
each one, whether a wall enforces it, how many tests violate it, and what the
wall would cost.

Then **build one** — the one where the gap between "we believe this" and "the
machine checks it" is widest.

One wall built and holding beats seven proposed.

## Ground yourself FIRST — find the walls that already exist

Do not design before you count. Several walls are already standing and at least
one was forgotten within weeks of being built.

Known, verified 2026-07-31:

- **`regression_lib.sh:608`** — `MUST_ERROR` must pin a diagnostic. Accepts five
  spellings: `expected_error.txt`, `expected.txt`, `expected_patterns.txt`,
  `post.sh`, or `CONTAINS`/`NOT_CONTAINS`/`STDOUT_CONTAINS:`/`ERROR_AT` in
  `EXPECT`. **Read the predicate before counting anything against it** — that is
  precisely the mistake this frame was born from.
- **`f1a74bd1`** — "zero tests matched is a failure, not a pass." A wall against
  the harness lying about coverage.
- **`690_099`** — a control that goes red the moment a store-name guard is
  loosened from prefix-anchored to substring. A wall spelled as a *test* rather
  than as harness code.
- **`110_029`** — deliberately machine-independent: it imports a module that
  *cannot* exist, so it asserts the alias is known rather than that a library is
  installed. A wall against a test that passes on the author's machine only.
- **`scripts/registry_check.zig`** — check what it enforces; it reads
  `error[KORU###]` pins.

Sweep `scripts/` and `run_regression.sh` for others. **Report the full list** —
that list alone has value, because a forgotten wall gets rebuilt or bypassed.

## ⭐ The wall this frame should probably build — found 2026-07-31

A candidate that already meets all four bars, discovered while probing challenge
`015`. **You may build this one without further argument; the count is done.**

The harness compares `expected.txt` (`regression_lib.sh:1490`). A `MUST_RUN` test
carrying only **`expected_output.txt`** — a filename nothing reads — **asserts
nothing** and passes if the program merely exits 0.

The inverse wall already exists: expected output with no `MUST_RUN` is a
`config-error` at `regression_lib.sh:581`, with the reasoning in the source —
*"Otherwise they dishonestly pass by claiming compile-only when they should
verify output."* The symmetric case was never built.

Measured across the corpus:

```
35   tests carry expected_output.txt
29   of those have NO expected.txt and NO expected_patterns.txt  → assert nothing
 4   are marked SUCCESS while actual.txt contradicts expected_output.txt
```

The four:

```
440_001_bridge_basic                actual: "FAIL: dispatch_error"
440_002_cross_session_discharge     actual: "FAIL: session 1 dispatch_error"
220_005_cross_module_type_nullable  expects "done", produces nothing
321_nested_recursive_label          "expected output" is a placeholder comment
```

`321`'s expected file reads *"// Expected output placeholder - test currently
fails at codegen stage"* — which is also a `feedback_no_state_prose_in_tests`
violation sitting inside an assertion file, so it fails two rules at once.

⚖️ Against the four-point bar: the rule is already believed (the inverse is
enforced and the source states why); violations are mechanically detectable
(`MUST_RUN` present, no readable expectation); it fails loudly and locally as
`config-error`; and **the corpus can pass it** — 4 tests go red, and those four
are *already broken and lying*, which is the wall working, not a regression.

⚠️ Two of the four are the entire evidence base for challenge `015`. Landing this
wall is what makes that frame honest, so **coordinate**: the wall belongs here,
the `dispatch_error` diagnosis belongs to `015`.

⛔ Do not rename the 29 files as a bulk fix. A file named `expected_output.txt`
beside a `MUST_RUN` means *somebody wrote an expectation and it was never
checked* — each one needs its output verified before its assertion is switched
on. Renaming them all at once would turn 29 unchecked assumptions into 29 claims
the board now makes.

## The rules that are still prose

Each of these is written down and believed. For each: does anything check it?
How many tests violate it today? Count, do not estimate.

**From `CLAUDE.md` (project):**
- *"Write what the test **pins** — the shape it guards. Not its red/green state,
  not why it fails today."* → Grep test headers for state prose: "currently
  fails", "this is red", "will pass once", "broken today". There is a standing
  correction behind this (`feedback_no_state_prose_in_tests`) and a sibling one
  about compensation prose in artifacts (`feedback_no_compensation_prose_in_artifacts`).
- *"Don't green-by-edit."* → Probably uncheckable directly, but a **proxy** is
  checkable: a commit that modifies a test's `expected_*` and nothing else.
- *"Ground truth is the tests."* → Is any documented claim unbacked by a test?
  `challenges/015` found a header claiming five behaviours with two tests behind
  them. That pattern is likely elsewhere in `koru_std/`.

**From the memory corpus:**
- *No lying tests* (`feedback_lying_tests_banned_aoc`) — a test whose expected
  output was derived from the implementation rather than the problem.
- *`[aspirational]` discipline* — deferred gaps marked, gated later. Is the marker
  used consistently? `44` todos carry an `ASPIRATIONAL:` prefix; do they match the
  convention, and does anything enforce it?
- *Default pure-Koru programs to `.k`* (`feedback_default_k_not_kz_for_pure_consumers`)
  — count `.kz` tests with no `~` and no Zig body. Those are `.k` files wearing
  the wrong extension.
- *`string` is the surface text type; `[]const u8` is rejected in all surface
  positions* (`baton_string_surface_text_type`) — is that enforced, or convention?

**From the board's own shape:**
- **Every comptime construct in `koru_std` should have a `115_*_in_module` mirror
  test.** Nothing checks this. See `challenges/011` — it wants the same wall, so
  coordinate rather than building it twice.
- **Every diagnostic code should have a test that pins it.** `registry_check.zig`
  may already do half of this; find out which half.

## ⚖️ The bar for a wall

A wall is worth building when **all four** hold. Test your candidate against
these before writing it:

1. **The rule is already believed** — you are compiling doctrine, not inventing it.
   ⛔ If you find yourself arguing *for* a rule, stop: that is a design question
   for Lars, not a wall.
2. **Violations are mechanically detectable** without judgement. "Pins no
   diagnostic" is mechanical. "Is a good test" is not.
3. **It fails loudly and locally** — on the board, naming the test, saying what to
   add. `regression_lib.sh:614-616` is the model: it prints the five acceptable
   fixes.
4. **The existing corpus can pass it**, or the violations are few enough to fix in
   the same piece of work. A wall that lands 200 tests red is not a wall, it is a
   regression.

That fourth point is the usual killer, and it is what makes the census the real
deliverable: **the count decides which wall is buildable.**

## The pre-garden

- **Are the existing walls still doing their job?** Test `regression_lib.sh:608`
  by temporarily emptying a pinned test's assertion and confirming it fails. A
  wall nobody exercises is a wall nobody knows is broken. (Revert after.)
- **Do the 4 currently-unpinned `MUST_ERROR` tests deserve pins, or deletion?**
  ```
  100_PARSER/100_083_unclosed_paren_in_capture_value
  100_PARSER/100_084_bare_module_call_in_kz_is_host_line
  200_COMPILER_FEATURES/210_PARSER/210_029_transform_requires_comptime
  300_ADVANCED_FEATURES/330_PHANTOM_TYPES/521_multiple_resources_partial_cleanup
  ```
  They are red as `config-error` today, so the wall is working — but four
  permanent reds against a working wall is the wall doing paperwork instead of
  guarding. Close them.
- **`73` test files carry `RED PIN` / `PIN (` header language.** Is that a
  convention with a shape, or seventy-three ad-hoc phrasings? If there is a shape,
  it is checkable, and a red pin that states its prediction is a test that can be
  told it was wrong.

## What "done" looks like

- **The census**: every rule, whether a wall exists, current violation count,
  and buildability against the four-point bar. This is the artifact.
- **One wall built**, holding, with the existing corpus passing it — or with the
  handful of violations fixed in the same work.
- Every wall found-but-forgotten written into the census so it is not rebuilt.
- The four unpinned `MUST_ERROR` tests closed.
- Any rule that turns out to be **contested rather than believed**, flagged as a
  question for Lars instead of enforced.

## Failure modes

- **Building a wall for a rule nobody agreed to.** Point 1 of the bar. This is the
  most likely way this frame goes wrong.
- **Counting with the wrong predicate.** The scoping for this frame did it twice,
  off by 167 and by 127. Read the harness's own condition and count with *that*.
- **A wall that lands the corpus red.** Point 4.
- **Seven proposals and no wall.** The census earns its keep by producing one.
