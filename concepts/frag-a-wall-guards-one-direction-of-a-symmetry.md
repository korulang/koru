---
type: belief
id: frag-a-wall-guards-one-direction-of-a-symmetry
provenance: four independent findings on 2026-07-31 — expected_output.txt, the BENCHMARK marker, the partial-filter drop, and the mirror wall's declaration form — each a rule enforced in one direction and not its mirror
ts: 2026-07-31
---

# A wall gets built where someone was bitten, so it guards one direction of a symmetry and not the other (belief)

Four separate defects surfaced in one day. Each looked unrelated. Each is the
same shape.

| enforced | not enforced |
|---|---|
| expected output with no `MUST_RUN` → `config-error` (`regression_lib.sh:581`) | `MUST_RUN` with no readable expectation → silent pass |
| `regression_lib.sh` honours a `BENCHMARK` marker | `save-snapshot.js` had never heard of it → 14 tests `untested` since January |
| a filter matching **zero** tests refuses (`f1a74bd1`) | a filter matching **some** silently drops the rest |
| the mirror wall reads `pub tor` in `koru_std/*.kz` | the same transform as `pub event`, or in a `.k`, ships unwatched |
| a duplicate `NNN_NNN` test id is refused (`prose-check` C) | an *orphan* test dir — build artifacts, no source — is invisible until it happens to acquire a twin |

In every case the guarded direction is the one that had already caused visible
pain. `regression_lib.sh:581` even records its own motive in the source —
*"Otherwise they dishonestly pass by claiming compile-only when they should
verify output."* Somebody was bitten by that exact case, wrote the wall for that
exact case, and stopped. The mirror was not rejected; it was never considered,
because nothing had gone wrong there yet.

## Why the mirror is where the damage accumulates

The guarded direction is, by construction, the one people already fear. The
unguarded mirror is the one nobody is watching — so defects there are not merely
possible, they are **selected for**: they survive precisely because no one is
looking.

The `BENCHMARK` case shows the full lifecycle. One half of the toolchain honoured
the marker, the other half had no concept of it, and the disagreement produced 14
tests that were skipped by the runner and counted as `untested` by the board —
in the denominator, dragging the published rate, explaining nothing, **for six
months.** Neither half was wrong on its own. The gap between them was.

## What this changes about how to look

The instinct when auditing quality rules is to survey doctrine: list what we
believe, check which beliefs have enforcement. That is the wrong first question,
and it is expensive — it produces a long list of walls to build, most of which
cannot be built because the corpus would go red.

**The cheaper and higher-yield question is: for every wall that already exists,
what is the mirror case it does not cover?** Three of the four above were found
by asking it. None were found by surveying doctrine. And the mirror wall is
almost always *buildable*, because its twin already proved the corpus can live
with the rule.

A corollary worth stating separately: **an inventory of existing walls is a
prerequisite, not a side quest.** Two of the four were walls nobody remembered
existed — see [[frag-compliance-is-counted-with-the-enforcers-predicate]], where
a forgotten wall caused the same corpus to be measured as 75% rotten when it was
98% sound.

## The fifth instance shows the failure mode from the other side

`git mv` on a test directory is half an operation: the tracked files move, the
untracked build artifacts stay, and the leftover directory keeps the old name.
When `335_020` was renamed, the orphan kept the same `NNN_NNN`, and
`prose-check` C refused the board on the duplicate — **the wall worked, on the
first run after the merge.**

But four *other* orphan directories were sitting in the corpus at that moment,
stranded by older deletions, causing nothing. They had no twin, so no rule
noticed them. The guarded case is "two dirs, one id"; the unguarded mirror is
"a dir with no source at all," which is the more common outcome of the same
mistake.

That is worth recording because it is the pattern seen from the *good* side: a
wall firing correctly is not evidence its mirror is covered, and the noisy case
is usually the rarer one. What made the four orphans harmless was luck about
numbering, not a rule.

## Open

- No inventory exists. Known so far: `regression_lib.sh:581` and `:608`,
  `f1a74bd1`, `prose_check.sh` check D, `scripts/registry_check.zig`, and the
  test-shaped walls `690_099` and `110_029`. Certainly incomplete.
- Whether a wall spelled as a **test** (`690_099`) resists this failure better
  than one spelled as **harness code** is untested. A test has a name, shows on
  the board, and is greppable by anyone auditing the corpus — which at least
  makes it discoverable. Whether that also makes its mirror more obvious is a
  separate question and I have no evidence either way.
- [[frag-a-misnamed-assertion-is-silently-no-assertion]] is the first instance,
  written before the pattern was visible. It states the rule in one line near the
  end; this concept is that line, promoted, once three more instances arrived.

## The sharpest instance: the wall's own message describes what it cannot see

`std/store` traps a STALE row handle — one whose row was removed — and pins it
both directions, write (690_115) and read (690_116). The resolve that does the
trapping also carries a second refusal, verbatim at `koru_std/store.kz:1864`:

> the value is not a handle this store issued (handles come from `| row` and
> row cursors)

That message has never been able to fire. `__koru_resolve` checks slot bounds
and generation and nothing store-specific, so two stores of the same shape
filled in the same order mint identical `slot|gen` values and each other's
handles resolve cleanly. Measured: a handle from `src` addressing `dst[r]`
writes dst's row and prints the wrong value, silently (690_196).

So the symmetry here is not stale-vs-fresh, it is **wrong-row vs wrong-store**,
and only the first half was ever built. What makes this the sharpest instance
in this belief is that no inference was required to notice it: **the guard
states the guarantee it does not provide, in its own error text.** Anyone
reading the resolve would come away believing foreign handles are caught.

- **A diagnostic is not evidence of a check.** An error message is a claim
  about the code's intent, and intent is exactly what rots. Grep the message,
  then find the branch that raises it, then ask what reaches that branch.
- **Where a wall traps a value's staleness, ask what traps its provenance.**
  Those are different questions and the first does not imply the second.

It was found by pointing a borrowed workload at the store, not by review — see
`frag-a-corpus-exercises-its-authors-idioms`.
