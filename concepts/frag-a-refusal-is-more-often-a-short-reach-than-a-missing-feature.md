---
type: belief
id: frag-a-refusal-is-more-often-a-short-reach-than-a-missing-feature
provenance: reading intranquil's plugin contract against `koruc lib`'s export surface 2026-08-10 — a Koru audio plugin looked blocked on an unbuilt feature and was blocked on one `startsWith("[]")`
ts: 2026-08-10
---

# A refusal usually marks a short reach, not a missing feature (belief)

When the compiler says no to something a real consumer needs, the reflex is to
read the no as a gap in what has been *built* — a rung not yet climbed, a design
not yet had. That reading is expensive: it turns a consumer's blocker into a
project, and it invites inventing an answer to a question that already has one.

The reading that has been right more often: **the answer exists, and only its
reach is short.** The vocabulary is already in the language; the check that
refuses simply never learned that this case is the same case.

Three instances, and the third is the one that named the pattern:

- A library needed no new marker. `pub` already meant "visible outside this
  module", and a library is just a compilation in which *outside* exists. The
  work was the root rule, not the surface.
- An empty box needed no new diagnostic vocabulary. The refusal and the emitter
  were already asking one question in two hand-kept copies
  ([[frag-a-wall-that-stands-down-program-wide-guards-nothing]]); the fix was
  deleting a copy.
- A run of samples needed no new C convention. Text had already crossed as a
  pointer and a length, for reasons that were about *C*, not about text — C has
  exactly one way to hand over a run of values it does not own. Numbers are the
  same case. The refusal was a type check that matched one spelling.

## The tell, and why it is hard to see from inside

The refusal is usually *well written*. It names itself, it explains the shape it
cannot represent, and its reasoning is locally correct — which is exactly what
makes it read as a considered boundary rather than an unfinished one. A sloppy
error invites a second look; a careful one closes the question.

So the discriminating move is not to reason about whether the feature exists. It
is to ask: **is there an already-accepted case that differs from this one only in
a detail the refusal's own justification does not mention?** If the stated reason
for accepting text is a fact about C rather than a fact about text, then every
type that shares that fact is already inside the reason, and the check is simply
narrower than the argument that produced it.

## What follows

- **Read the refusal's justification, not its condition.** The condition says
  what is currently matched; the justification says what was actually decided.
  Where they disagree, the justification is the design and the condition is a
  transcription of it that stopped early.
- **Price it before scheduling it.** "Consumer blocked on an unbuilt feature" and
  "consumer blocked on a check that matches one spelling" are hours apart, and
  the second is common enough to be the first hypothesis.
- **Generalising is not widening.** The refusal must stay exactly as loud for
  everything the justification really does exclude — a buffer return still has
  nowhere to put a length, and that no is unchanged.

## Open

Whether this is checkable rather than remembered: a lint that flags a type check
enumerating a set narrower than the set its own doc comment argues for. The three
instances here were all found by a consumer hitting them, which is the slowest
possible discovery route.
