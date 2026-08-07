---
type: belief
id: frag-one-consumer-not-reading-something-is-not-evidence-that-none-does
provenance: 2026-08-07 — reported that the RULING marker was read by nothing and that its passing-test wall needed building; both false, and the refuting file was in my own grep output
ts: 2026-08-07
---

# A verified "X does not read this" does not license "nothing reads this" — and the consumer list is usually already in the output you skimmed (belief)

The shape is a true measurement promoted, silently, into a false universal.

The instance: asked whether the suite had a way to mark a test as blocked on a
human decision, I grepped `run_regression.sh` for `RULING`, got zero, and
reported that nothing read the marker and that the invariant "a passing test may
not carry one" needed building.

Both halves were wrong, and expensively so — the recommendation that followed was
to build three things that existed. `scripts/rulings.js` is a queue command that
prints every pending question with its board status. `scripts/prose_check.sh`
check E already walls the exact invariant under the name `RULING-ON-PASSING`,
with the same reasoning about what a green over an open question means. And
`run_regression.sh:62` runs that check on every board, so it was already
enforced.

**The refuting file was in my own tool output.** A second grep for consumers had
returned `scripts/prose_check.sh` in a six-line list, and I read past it because
I had already formed the answer and the other five entries were the word
appearing in ordinary prose. The zero from `run_regression.sh` was correct; every
inference after it was unearned.

## What makes this different from ordinary carelessness

The first measurement being *right* is what makes it dangerous. A grep that
returns zero feels like proof, and it is — of a proposition much narrower than
the one it gets used for. `run_regression.sh` genuinely does not mention the
marker; that fact survives. It simply never implied the universal.

The tell is a scope word appearing between the measurement and the conclusion:
grepped *one file*, concluded about *the toolchain*. Whenever a sentence moves
from a named artifact to a category — "the harness", "the pipeline", "nothing",
"anywhere" — the widening is a separate claim and needs its own check.

## What follows

- **Before reporting an absence, name what you searched and let the scope of the
  claim match it.** "`run_regression.sh` does not read it" is publishable on one
  grep. "Nothing reads it" needs the consumer sweep, and the sweep is cheap.
- **Read your own tool output before it scrolls.** The cost here was not a missing
  command; it was skimming a result that contained the refutation.
- **An absence is a claim about the whole system and therefore the expensive kind.**
  Presence needs one witness; absence needs exhaustion. Weight them differently.
- Same family as
  [[frag-a-reproducible-failure-localises-the-symptom-not-the-defect]]: both are
  a real observation carrying an unearned inference about scope.
