---
type: belief
id: frag-a-fixed-defect-uncovers-the-next-one-behind-it
provenance: 210_166 closed the prefix-before-fold capture; 210_170 is a second, independent defect at the identical position, unreachable until the first stopped failing
ts: 2026-07-26
---

# A defect early in a pipeline hides every defect behind it at the same input (belief)

A compiler is a sequence of stages, and a program that dies in one never reaches
the next. So a defect is not merely a bug — it is a **lid** on every later-stage
defect that the same program would have triggered. Fixing it does not close the
shape it lived in; it exposes however much of that shape was standing behind it.

The prefix-before-fold position is the worked instance. `210_166` closed the
emitter's discarded capture there. `210_170` is a second, entirely separate
defect at the same position — the effect-branch Handlers type is not threaded
through a prefixed fold — and it was invisible while the first one held, because
nothing that exercises Handlers threading can run in a program that fails
earlier in emission. Both are real, both had always been there, and no amount of
probing would have surfaced the second before the first was fixed.

## What follows

- **A green pin closes a defect, never a position.** "We fixed the prefixed
  fold" is the sentence to avoid; "we fixed the capture in a prefixed fold" is
  what was actually done. The difference is exactly the second defect.
- **After a fix lands, re-probe the shape rather than the pin.** The pin is now
  green by construction. What earns its keep is running the *neighbourhood* the
  fix opened access to — the richer programs that could not previously get far
  enough to fail.
- **Estimates of remaining work at a known-bad position are unfounded.** Nobody
  can count the defects behind a lid, so "one more fix and this shape works" is
  a guess dressed as a plan. It stays a guess until the shape runs.

This is why a fix and its verification are not the same act, and why the
verification worth running is broader than the thing that was fixed.

## Not the same as reach

[[frag-the-minimal-test-of-a-wall-cannot-test-its-reach]] is about a check
covering part of what it claims — one position, one spelling. This belief is
about *ordering*: two complete, unrelated faults, where one is simply upstream
of the other for a given program. A check with perfect reach still gets its
later stages hidden by an earlier crash, and widening coverage does nothing
about it.

## Open

Whether anything mechanical helps. A stage that continued past a defect to
collect later-stage errors would surface the lid's contents in one run, which is
what error recovery buys a parser — but the emitter operates on a tree the
frontend has already accepted, and a program that emits malformed host code has
no meaningful "continue". More likely this stays a habit: after any fix at a
position, go write the ambitious program the position is *for*, and see what it
hits now.
