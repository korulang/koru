---
type: belief
id: frag-a-gate-that-fails-conservative-is-invisible
provenance: 2026-08-03 — the dense-cursor optimisation shipped and was measured at ~5.7x, then found to be gated on a substring search for "take" over the whole program, so it was silently off for any program containing the store's own `taken` obligation spelling
ts: 2026-08-03
---

# A gate that fails conservative is invisible, and nothing in the corpus can find it (belief)

A safety wall that fails *permissive* eventually announces itself: something
corrupts, or a test goes red the day the wall is closed. The brand-0 belief is
that story — the hole was occupied, and closing it turned green tests red, which
is an invoice but also a *signal*.

A performance gate that fails *conservative* has no such day. Choosing the slow
path is always correct. No test can assert against it, no oracle disagrees, no
checksum moves. It is not a latent bug waiting to fire; it is a permanent tax
that never files a report, and the only thing that finds it is someone reading
the predicate and asking what it actually matches.

## Why this one lasted

The predicate was a substring search over the program's whole text. It was
written as a deliberately blunt over-approximation, and the comment beside it
said so — the intent was honest and the direction was safe. What nobody checked
was the *matching*, and a substring for the removal verb also matches the
store's own obligation vocabulary. So the class of program most likely to want
the optimisation — an entity store with a despawn discharger — was the class
guaranteed not to get it. A cross-store removal disabled it too, which in a
many-store workload means always.

Two properties compounded. The gate was **whole-program** when the hazard is
per-store, and it was **lexical** when the hazard is semantic. Either alone
would have been a wide net; together they made the optimisation approximately
unreachable in real code while measuring perfectly in the benchmark, because the
benchmark is the one program shape that never removes anything.

## What follows

- **A conservative default is not a safe default; it is an untested one.** When
  a gate picks between a fast and a slow path, the fast path needs a test that
  asserts it was *taken* — the slow path's correctness proves nothing about
  reachability. Assert on the emitted shape, not just the output.
- **Ask what a predicate matches, not what it means.** The comment describing a
  gate is its author's intent; the condition is its behaviour, and the two drift
  in exactly the direction where nothing complains.
- **A benchmark that avoids the hazard also avoids the guard.** A suite whose
  programs never remove a row cannot observe a removal-gated decision. Measuring
  the fast path while shipping the slow one is a coherent, reproducible, wrong
  answer about what users experience.
- **Suspect any optimisation whose enabling condition is a whole-program
  property.** The hazard nearly always has a scope, and a gate coarser than the
  hazard is off for everyone who shares a program with one instance of it.

## Confirmed while chasing it, against the optimizer

Two "obvious" redundancies found by reading — a validation performed twice, and
a call repeated where one binding would do — both measured exactly neutral.
Reading source finds waste the optimizer has already removed, which the corpus
already believes; what is new is the other direction: an attempt to remove one
of them by restructuring measured **worse than the bug being fixed**, because
the restructure moved the success path deeper into the branch nest. Shape
dominates branch count here by a wide margin, and neither effect is visible in
the source.

## Open

Whether the hazard's real scope is per-store or per-pass. Per-store is what is
built and it is still an over-approximation: a pass is straight-line, so the
question is whether *this* pass can reach a removal, not whether the program
contains one anywhere. The corpus already holds the pieces — that a rule's
footprint is its own body's touches, and that subflows are chaseable — so the
narrowing is available and unclaimed. The current gate is honest about being
coarser than necessary; the previous one was not coarse, it was wrong.
