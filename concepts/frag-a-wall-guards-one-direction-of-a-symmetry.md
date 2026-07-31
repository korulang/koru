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
