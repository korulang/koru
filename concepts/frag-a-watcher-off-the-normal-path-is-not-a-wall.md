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

## Open

Whether the other end-of-run steps that parallel mode skips matter as much. The
snapshot write and test-index generation are already gated on a full run in both
paths; nothing else was audited when this was found, and a second pass over what
diverges between the two paths has not been done.
