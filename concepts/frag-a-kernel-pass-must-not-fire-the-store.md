---
type: belief
id: frag-a-kernel-pass-must-not-fire-the-store
provenance: designed with Lars 2026-07-30, in the conversation that began by asking whether the Fast Multipole Method fits std/kernel; the bypass was his framing and the justification below is what it turned into when we asked why it was allowed
ts: 2026-07-30
---

# A bulk numeric pass over a store must not fire the store's machinery — because firing would BREAK the guarantee, not honour it (belief)

The obvious reading of a kernel operating directly on a store's columns is that
it cheats: it skips the interceptors, the watches, the standing rules, and buys
speed with that. Speed is real and it is not the argument. The argument is that
firing would be **wrong**.

The store's headline guarantee is that no observer ever sees mid-cascade state —
the atomicity unit is a write plus its full cascade, and watches only ever
observe a settled world. A bulk pass is definitionally mid-cascade for its entire
duration: half the corpus transformed, half not, an intermediate that corresponds
to no consistent state of the thing being modelled. Firing per element would show
every observer precisely the state the guarantee promises they will never see.

So the bypass is required BY the guarantee. A kernel that politely routed its
writes through the reactive path would be the version that violates the store's
own contract.

## It is not a hole in the model — it is the slot opposite the announce verb

The store already distinguishes changing the corpus from telling the rules about
it: there is a verb whose whole job is "run the compiled rules across the corpus
once, now." That verb only makes sense in a world where firing is something a
program ASKS for rather than something that merely happens. A pass that computes
without firing, followed by an explicit announce, is the shape the store already
has vocabulary for. The kernel fills the other side of a distinction the store
drew for itself.

## What the bypass costs, and the three conditions

**It must be declared, not incidental.** A watch that silently fails to fire
while a kernel moves every value it watches is exactly the case the no-fallbacks
law is about: a reader must not mistake a quiet non-firing for a working reactive
surface. This is the condition to hold hardest, because it is the one that looks
like a nicety and is not.

**Scalars only.** A column that owns an obligation carries discharge in its write
path; a raw column write goes around it. That is not a performance question, and
it does not trade off against anything.

**The corpus is frozen for the duration** — no structural mutation while a pass
runs. This constraint arrives independently from the aliasing question and from
the reactive question, by arguments that share no premises. Two derivations of
one rule is usually the sign that the rule is real rather than convenient.

## The part that cannot be reconciled, and why that is cheap

Observers that read current state can be caught up afterwards by the announce
verb. Observers that need a BEFORE-image cannot be caught up at all: a bulk pass
destroys the old value, and recovering it means shadow-copying the column, which
is the exact cost the pass exists to avoid.

The right answer there is a refusal, not a synchronisation primitive. A field
whose observers need a before-image is simply not a field a kernel may touch. The
discrimination is already computed for unrelated reasons — the store only
materialises an old image when some arm actually needs it — so this costs one
comptime check instead of an entire surface. **A synchronisation problem that
collapses into a refusal was never a synchronisation problem.**

That generalises past this case. Reaching for a coordination primitive is worth
suspecting whenever the thing being coordinated has no concurrency in it; what
looks like synchronisation is usually sequencing, and sequencing questions are
answered by refusing the cases that cannot be ordered rather than by building
machinery to order them.

## Open

- Whether the borrow should be visible in the type system as a state on the
  corpus, rather than enforced by a placement rule. It is the same shape as the
  obligation the store already puts on a taken row, one level up. See
  [[frag-an-obligation-is-a-liveness-interval]].
- Whether "declared, not incidental" is a diagnostic, an annotation, or a
  refusal when a watched field is touched. The spelling is Lars's; the
  requirement is not.

Related: `frag-store-verb-placement` (the momentary/standing split this rests on),
[[frag-observability-is-not-explanation]].
