---
type: belief
id: frag-a-watcher-off-the-normal-path-is-not-a-wall
provenance: found while wiring check D into prose-check 2026-07-26 — the watchers sat past the point `--parallel` exits, so the mode the toolchain skill tells you to use had never run them; prose-check's check A had been failing on the event→tor rename for as long as that rename had existed
ts: 2026-07-26
---

# A guard is only as strong as the path that reaches it (belief)

`run_regression.sh` grew two coherence watchers — diagnostic-code registry drift,
and the no-prose pipeline check — both written as blocking, both commented as
blocking, both appended at the end of the sequential run. Parallel mode returns
several hundred lines earlier. So `--parallel`, which is the invocation the
toolchain skill hands you as *the* way to run the suite, had never executed
either one.

Nothing about this is visible from reading the watchers. They are well written and
they do fire — when reached. The defect is entirely in the topology, and topology
is what nobody re-reads.

## The cost, measured

prose-check's check A compares every generated artifact against its own
regeneration. It had been failing since the `event` → `tor` rename: the by-example
corpus and three generated SKILL.md files still said `~event`. The check designed
to catch exactly that drift had been reporting nothing, because it never ran.

Its check C forbids duplicate `NNN_NNN` test ids. Two sessions independently took
`210_166` the same day. That collision would have been caught at the next full
run — and would not have been, since the next full run was going to be parallel.

## What follows

- **A guard's strength is the probability the normal path reaches it, times its
  logic.** Reviewing only the logic reads the second factor and assumes the first.
- **When a fast path is added beside a slow one, the guards do not come along.**
  The fast path is written by copying the reporting and exit logic, which is
  exactly where end-of-run checks live, and exactly what gets trimmed. Extract to
  a function called from both, so adding a third path has to name it or visibly
  omit it.
- **Prefer the failure that is loud in the common case.** These watchers were
  unreachable in the common case and reachable in the rare one, which is the worst
  arrangement: they cost nothing to keep, produced nothing, and read as coverage.
- **"Blocking" in a comment is a claim about intent, never about reach.** It is
  the same class of thing as a red pin's title — see
  [[frag-a-red-pin-is-unfalsifiable-documentation]] — an assertion no assertion
  checks. The defence is to run the guard and watch it fail on purpose.
- **Reach is necessary and not sufficient: a wall also needs a CONSUMER.** A
  guard that runs, fails, and prints into a log nothing downstream reads is
  back where it started. The question has two halves — does the normal path
  reach it, and does anything act on the answer.

## The same failure one layer in: a guard whose input is not tracked

Check D shipped with its manifest untracked. `tests/regression/.gitignore` is an
allowlist — `*`, then the kept patterns — and the manifest's extension was not on
it, so `git add <path>` printed an advisory hint and exited 0. The commit
succeeded; the lint's only input did not travel with it. For anyone else the check
would have failed with MISSING-MANIFEST, pointing at the manifest rather than at
the ignore rule that ate it.

Same shape as the topology defect: logic sound, reach zero. Reaching now means
being present in the clone, not merely being called. And staging narrowly —
adopted in that session as protection against a concurrent writer in the same
checkout — is what removed the `git add -A` whose diff would have shown the gap.

## The third rung: reached, fired, and published over anyway

Reach was fixed and the belief still had a hole. Check D now runs — and on
2026-08-02 it fired, correctly, on the `sweep`→`query`/`query`→`rule` rename:
a stale row for a transform `koru_std` no longer declares, and no row at all
for the one the rename created. It had been firing since the rename landed.

A full board was published over it in between. The status ceremony reads
`test-results/latest.json`, whose schema carries a pass count, categories and
unit tests — **and no wall verdicts at all**. So the suite says ❌ at the end
of a run whose snapshot says 1294/1451, and every consumer downstream of the
snapshot sees only the number. Nothing in the publish path can even ask
whether a coherence wall was red.

This is the same defect one layer out, and it is the more dangerous layer:
the topology bug hid a wall from the runner, this one hides it from the
*record*. A wall that fires into a transcript a human may or may not scroll
to is a watcher again, and the fix is the same shape — the verdict has to
travel in the artifact the consumers actually read, not in the log of the run
that computed it. Neighbour on the artifact side:
[[frag-a-verdict-read-from-an-artifact-does-not-cover-the-run]], where the
artifact could not show the failure; here the artifact simply never carries
it.

## The fourth rung: a MARKER whose name claims a state it does not implement

Every rung above is about a guard that was meant to run. This one is about a
guard that was never going to, where the giveaway is a filename.

A test directory holding a `TODO` file is reported as `📝 TODO`, counted in its
own column beside passed and failed, and **returned from before the test is
executed at all**. It is a skip wearing the vocabulary of a backlog. Sixty-seven
test directories carried one when this was measured (2026-08-04), so the suite
has a third column that reads as work-in-progress and contains no verdicts.

The cost is specific and it is not the wasted coverage. The project's own
contributor guidance describes aspirational tests as the right move — add one
failing, *flip it to passing when the feature lands*. That promise needs the test
to RUN and go green on its own. A `TODO` test cannot flip: it produces the same
cheerful `📝` the day the feature ships as the day it was filed, and the only
thing that ever changes it is a human remembering to delete the marker. So the
mechanism that exists to track intended work is the one thing guaranteed not to
notice the work being done.

This extends the belief's existing line about comments — "'Blocking' in a comment
is a claim about intent, never about reach" — one step, and the step matters:
**a marker's NAME is that same unchecked claim, and it is more convincing than a
comment**, because a file called `TODO` in a directory of markers reads as
machinery rather than as prose. Nobody re-reads topology; nobody re-reads a
filename's semantics either.

- **Ask of every marker what state it asserts and what the runner does with
  it.** `SKIP` and `TODO` differing only in which counter increments is a
  distinction with no consequence, presented as two categories.
- **An aspirational test's whole value is that it is RED.** Red is the state that
  flips by itself, that shows up in a regression count, and that a reader can
  act on. Choosing a label that suppresses execution to keep the board tidy trades
  the one property the test was created to have for the appearance of not having a
  problem.
- **The falsifier, stated plainly:** if something does re-run TODO-marked tests
  and reports the ones that have started passing, this rung is wrong and should be
  `correct`ed rather than evolved. Nothing found does, which is why it is written
  as a claim about reach and not about intent.

## Open

Whether the other end-of-run steps that parallel mode skips matter as much. The
snapshot write and test-index generation are already gated on a full run in both
paths; nothing else was audited when this was found, and a second pass over what
diverges between the two paths has not been done.
