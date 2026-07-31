---
challenge: honest-board
kind: frame
status: standing
yields: every test on the board either renders a verdict or says in its own words why it cannot
family: toolchain
---

*Walker context — the recurrence that earned this frame. The board publishes
**1154/1363, 84.7%**. That arithmetic has a hole in it: 1154 passed plus 195
failed is **1349**. The missing **14** are `untested` — and `untested` is not a
category anyone chose. It is the **default** when a test directory finishes with
no `SUCCESS`, no `FAILURE`, no `TODO`, no `SKIP`, and no `BROKEN` marker
(`scripts/save-snapshot.js:131`).*

*The harness already knows this is wrong. `save-snapshot.js:250` says so in the
source:*

> *inScope: … Includes untested (those **should** have run — if they didn't it's
> a real gap).*

*So fourteen tests sit in the published denominator, drag the rate down, and
render no verdict and no reason. All fourteen are in `420_PERFORMANCE` — the
category that would back every performance claim we make.*

*Alongside them: **102 todos**, of which **44 carry one of two identical
sentences**, and 3 skips. In total **105 of 1468 tests are sidelined**, and the
board's honesty rests entirely on whether each of those exclusions is true.*

---

## The brief (sealed — you are the contestant)

Every test on the board must render a **verdict** or a **reason**. No test may be
silent by default.

Close the gap in that order: first the fourteen that say nothing, then the todos
that all say the same thing, then the skips.

**This frame does not fix features.** A test that is red at the end of it is a
success, provided it is red *out loud*.

## The fourteen — start here, they are the whole point

```
420_PERFORMANCE/1210_array_by_reference        420_PERFORMANCE/420_001_profile_metatype
420_PERFORMANCE/420_002_profile_release        420_PERFORMANCE/420_003_profiler_loop
420_PERFORMANCE/420_006_rings_vs_channels      420_PERFORMANCE/420_007_simple_loop
420_PERFORMANCE/420_009_multi_consumer_async   420_PERFORMANCE/420_011_loop_optimization_basic
420_PERFORMANCE/911_generic_ring_type          420_PERFORMANCE/912_generic_ring_actual
420_PERFORMANCE/913_ring_with_taps             420_PERFORMANCE/914_ring_with_when_filter
420_PERFORMANCE/915_when_at_callsite           420_PERFORMANCE/916_ring_with_multitaps
```

They have `skipReason: ""`, `todoDesc: ""`, `brokenReason: ""`. Nothing.

For each one, find out **which** it is:

1. **It ran and left no marker** — a harness bug, and the most important outcome
   here. `f1a74bd1` already fixed one of this species ("zero tests matched is a
   failure, not a pass"), so the class is live.
2. **It never ran** — the harness skipped it silently. Find out why: no `EXPECT`,
   a malformed marker, a category-level condition, a benchmark path that opts out.
3. **It cannot run here** — needs hardware, a profile build, a flag. That is
   legitimate, and it is a `SKIP` **with the reason written in it**.
4. **It is dead** — pins a retired design. Delete it and say what it pinned.

Note that eight of the fourteen are `ring`/`generic ring` tests. That is a
cluster, and it probably has one cause. Check `420_PERFORMANCE`'s own
configuration before diagnosing fourteen tests individually.

⚠️ The stakes are specific: these are the **perf** tests. `baton_profiler_revival_and_std_compiles_lint`
and the perf boards depend on this category meaning something. Right now it means
nothing, silently.

## ⭐ WHAT THE FOURTEEN TURNED OUT TO BE — closed 2026-07-31

One cause, not fourteen. `400_RUNTIME_FEATURES/420_PERFORMANCE/BENCHMARK` was a
**category-level** marker: `regression_lib.sh` honours it and skips every test
beneath it before `koruc` is ever invoked, while `save-snapshot.js` had **no
recognition of `BENCHMARK` at all** and defaulted them to `untested`. Silent
since the marker landed in January, and in the published denominator the whole
time.

The marker was also over-broad — only 4 of the 25 entries in that directory are
real benchmark drivers, and those carry `input_taps*.kz` rather than a canonical
`input.kz`, so the corpus never counted them anyway. The rest are ordinary
feature tests: generic ring types, taps, when-at-callsite, array-by-reference.

Verdicts now: **2 pass, 12 fail loudly.** `untested` is 0 board-wide.

⭐ **What the twelve reds actually are, and it is not what it looks like.** Eight
fail on **pre-bare-return syntax** — *"single continuation branch carrying a
payload is a one-variant tag union — declare the single output as a bare return
instead: `-> <type>`"*. Three are a backend codegen mismatch on `.result`/
`.output` field access against a value a bare-return tor now hands back
unwrapped. One fails its `post.sh`.

So the concurrency corpus is **stale, not broken**. The language moved under it
during the bare-return migration and nobody migrated it, because the gate meant
nobody could see it. That is migration debt with a known cause and a diagnostic
that names the fix — a cheap, mechanical job, and explicitly **not** a
concurrency investigation. Anyone reading "ring tests are red" as "threading is
broken" has the wrong end of it.

## The 44 identical todos

```
430_RUNTIME              37 × "ASPIRATIONAL: the runtime interpreter is deferred pending a rewrite."
410_BUDGETED_INTERPRETER  7 × "ASPIRATIONAL: the budgeted interpreter is deferred pending a rewrite."
```

Forty-four tests asserting a plan in unison. The question is not whether they
should be todo — it is whether **that sentence is still true**, and whether one
sentence should stand for two different subsystems.

⛔ **Do not resolve this yourself.** It belongs to `challenges/014_the_interpreter_reckoning.md`,
which is a survey with a standing park over it. What you may do here:

- Confirm the count and that the strings really are identical.
- Establish whether 410 and 430 are the same system (the parked memory implies
  410 is a **predecessor**, in which case its 7 todos pin a design that was
  already replaced — "deferred pending a rewrite" would be false for them).
- Hand that to 014. Do not touch `koru_std/runtime.kz` or `interpreter.kz`.

## The rest of the 102

Fifty-eight todos live outside the interpreter family, in eighteen categories.
For those, apply the ordinary test:

- **Does the `TODO` say what is missing, or just that something is?** A todo is a
  promise; an unspecific one cannot be redeemed or retired.
- **Is it still deferred?** `320_048` was a red pin that predicted its own fix and
  went green on it. A todo can rot green the same way. Any todo whose feature has
  since landed is a test we are not running for no reason.
- **`61` `TODO` marker files exist against 102 todo statuses.** The difference is
  category-level inheritance (`save-snapshot.js:126`). Verify that every inherited
  todo is intentional — a whole category marked todo silently sidelines every test
  added to it afterward, including good ones.

That last one is the highest-yield check in this section.

## The pre-garden — is the board's own arithmetic honest?

- **Verify the rate.** `passRate = passed / inScope`, `inScope = total − todo −
  skipped − broken` (`save-snapshot.js:252`). So **untested counts against us**
  and todo does not. Confirm that is deliberate, and that the published surface
  on korulang.org says which. A rate whose denominator silently excludes 105 tests
  is defensible; one that does not *say so* is not.
- **Check `mustRun`.** Tests carry a `mustRun` flag that does not appear in the
  summary at all. Find out what it gates and whether anything is being excluded by
  it without being counted as excluded.
- **Category-skipped tests** report `skipReason: "Category skipped"` — a synthesised
  string, not an authored one. Every category-level skip should have a real reason
  somewhere; find where, or note that it does not exist.

## What "done" looks like

- **Zero `untested` on the next full board.** Every one of the fourteen is now
  success, failure, or a `SKIP` carrying an authored reason.
- Any harness bug found in the process, fixed, with a test.
- Todos with unspecific descriptions rewritten to say what is missing.
- Todos whose feature has landed, un-todo'd — and honestly reported if they are
  then red.
- A short written account of what the published rate excludes, suitable for the
  site to state plainly.

## ⚖️ The rate may go down. That is fine.

Fourteen untested becoming fourteen failures moves nothing in the denominator and
nothing in the numerator — but it turns a silence into a report. Un-todo'ing a
stale todo *grows* the denominator and can lower the percentage.

**Lower and true beats higher and silent.** Report the movement and where it came
from; `49ebca92` already set the precedent of publishing a dip and naming it
denominator growth.

## Failure modes

- **`SKIP`-ing the fourteen to make them go away.** A skip without an authored
  reason is the same silence with a different name.
- **Wandering into the interpreter.** Parked. Count, characterise, hand to 014.
- **Marking anything `TODO` to move it out of the denominator.** That is the one
  move this frame exists to prevent.
- **Publishing mid-frame.** The full board is for publishing. Run the affected
  categories while iterating.
