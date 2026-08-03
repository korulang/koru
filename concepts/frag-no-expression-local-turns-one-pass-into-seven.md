---
type: belief
id: frag-no-expression-local-turns-one-pass-into-seven
provenance: boids port 2026-08-03. Written wrong, corrected once when the measurement inverted, then corrected again when Lars asked "did you consider using capture?" — the construct the whole belief assumed was absent. The id keeps its original wrong name because ids are opaque and never renamed.
ts: 2026-08-03
---

# Where a per-element intermediate LIVES is the cost, and Koru has locals — I twice reasoned about the language from a structure I had chosen myself (belief)

## The premise was false

Koru has an expression-local binding. It is `capture`, it nests under an effect
arm, and a store query arm is an effect arm — so a per-row computation can hold
its intermediates in named local slots and never touch a store column. Both
earlier versions of this belief were built on the assumption that no such thing
existed. I never looked; the corpus has had `capture` under every other nesting
position for as long as the nesting sweep has existed.

## What is actually true, measured

The steering holds four intermediate vectors. Same arithmetic, same
bit-identical checksum, five shapes, one variable — where the intermediates sit:

- locals in a `capture`, one traversal — **fastest**
- store columns, seven traversals — ~7% slower
- store columns, progressively fused — degrades slowly
- store columns, one traversal — **~1.6x slower than locals**

Two facts fall out. **Locals beat columns**, which is unsurprising and is what
the whole detour was reaching past. And **routing intermediates through columns
gets WORSE as you fuse the passes**, which is the opposite of what anyone would
predict, and is the finding worth keeping.

The mechanism behind that inversion is in the emitted code: a multi-field store
write emits one write-path call per FIELD, and each call carries the entire
row's value slots, zeros included. It is free only while the call inlines and
the field selector folds. A body small enough to inline pays nothing; a body
large enough to defeat the budget pays for every slot at once. So the store's
write path has a cost that is invisible at every size anyone has tried and then
arrives all at once, and which side of the line a program is on is not visible
in its source. Why the fused body crosses it — inlining budget, register
pressure, lost vectorization — is untested, and the ladder in the benchmark is
the instrument that would separate them.

## The methodological residue, which is the real content

Twice in one session I generalised about the LANGUAGE from a structure I had
authored, and twice the generalisation was wrong in a way that flattered the
narrative: first "the language forces multiple passes" (it does not), then
"multiple passes are therefore the fast shape" (true only among the shapes I had
tried). Both survived my own review because the code in front of me really did
have the property I was describing — I just had no evidence it was the
language's property rather than mine.

The check that would have caught both is the same one and it is cheap: **before
concluding a language lacks something, search the corpus for the thing.** Not
the docs — the corpus. `capture` appears in a dozen nesting-sweep tests. A grep
would have ended this before the first wrong sentence was written.

The second-order lesson is about who caught it. Both corrections came from being
challenged by someone who knew the language, not from any test — every variant
was green and produced identical checksums the whole way through. A green board
has no opinion about whether your explanation is the right one.

## Open

- Why the column-routed fused body falls off the cliff. Three candidates named
  above; the ladder is committed and can settle it.
- Whether the remaining verbosity wants anything. `capture` names an
  intermediate but nothing names a subexpression WITHIN one, which is why the
  steering is still ~12.7k characters from about 40 lines of C#. That is a real
  gap and it is a smaller one than the belief originally claimed.
