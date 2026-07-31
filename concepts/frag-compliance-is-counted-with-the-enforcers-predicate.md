---
type: belief
id: frag-compliance-is-counted-with-the-enforcers-predicate
provenance: board triage, 2026-07-31 — measuring "how many negative tests pin no diagnostic" returned 171/227, then 131/227, then 4/227, the last one after reading the harness condition that had been enforcing the rule all along
ts: 2026-07-31
---

# Compliance with a rule is counted with the enforcer's predicate, never with your reading of the rule (belief)

The doctrine is one sentence: *a `MUST_ERROR` test must name the diagnostic that
refuses it.* Measuring compliance looked trivial — count the negative tests, count
the ones carrying a pin, subtract.

It was measured three times.

**171 of 227.** Predicate: is the `MUST_ERROR` file itself non-blank? Wrong,
because the pin does not live in that file.

**131 of 227.** Predicate: does an `expected_error*` file exist beside it? Closer,
and still wrong — it was one of five accepted spellings.

**4 of 227.** Predicate: the one at `scripts/regression_lib.sh:608`, which accepts
`expected_error.txt`, `expected.txt`, `expected_patterns.txt`, `post.sh`, or a
`CONTAINS`/`NOT_CONTAINS`/`STDOUT_CONTAINS:`/`ERROR_AT` line in `EXPECT`.

The first two numbers were not near-misses. They described a corpus in crisis —
58% to 75% of negative tests allegedly passing on any failure at all — and the
real corpus was sound, because the rule had been compiled into the harness weeks
earlier and had been quietly holding ever since. The four exceptions were already
red on the board as `config-error`, exactly as designed.

## Why the wrong predicate is the *likely* one

A rule stated in prose has a natural reading, and the natural reading is almost
never the enforced one. Enforcement accretes cases: the harness comment at
`regression_lib.sh:605` records that omitting `expected.txt` from the accepted
set "over-fired on five real, properly-pinned tests." Someone met reality and
widened the predicate. The prose did not widen with it, because prose does not
have to run.

So the gap is structural, not careless. **Every enforced rule drifts wider than
its statement**, and anyone measuring from the statement measures a corpus that
does not exist.

## What this costs when it goes unchecked

Both wrong counts were on their way into a commissioning brief as the headline
finding — *the negative-test corpus is rotten, go fix 131 tests*. That brief would
have sent work at a problem that was already solved, and it would have done it
in the confident register, with a number attached. A measurement is more
dangerous than a guess precisely because it is quotable.

The general form: **a number derived from a plausible predicate is not evidence,
it is a hypothesis wearing evidence's clothes.** The check is cheap — find the
code that enforces the rule and read its condition — and it inverted the
conclusion twice.

## The second finding, which is the one that generalises

The wall at `regression_lib.sh:608` had been forgotten by the party that most
needed it. Not bypassed, not broken — *unknown*. It does not appear in
`CLAUDE.md`, it has no name, and nothing indexes it. It is discoverable only by
grepping the harness for the symptom it prevents.

**A wall nobody remembers is indistinguishable from a wall that does not exist**,
right up until someone counts — and then it is worse than either, because the
count comes back describing a catastrophe that the wall has been silently
preventing all along. The wall keeps working. The belief about the system rots
anyway.

That is the argument for a census of walls rather than a habit of building them.
The build is the cheap half; staying discoverable is the half that decays.

## Open

- No inventory of the suite's walls exists. Known so far:
  `regression_lib.sh:608`, `f1a74bd1` (zero tests matched is a failure),
  `690_099` and `110_029` (walls spelled as tests), `scripts/registry_check.zig`.
  The list is certainly incomplete, which is the point.
- A wall spelled as a *test* (`690_099`) is more discoverable than one spelled as
  harness code — it shows on the board and it has a name. Whether that makes it
  the better form, or just the more visible one, is untested.
