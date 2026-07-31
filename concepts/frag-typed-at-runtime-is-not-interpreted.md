---
type: belief
id: frag-typed-at-runtime-is-not-interpreted
provenance: the resource-bridge design conversation, 2026-07-31 — "if the interpreter will ever be able to do partial evaluations it literally NEEDS to store the obligations and types fully at runtime… I was hoping we'd be able to run this at systems level speed"
ts: 2026-07-31
---

# A conversational system needs its *state* typed at runtime, not its *execution* interpreted (belief)

The resource bridge has to support picking a session back up: a fragment of Koru
arrives later, referring to a resource opened earlier, and must be checked
against what that resource currently is. The obvious reading is that this forces
an interpreter — and with it, the loss of systems-level speed, which is the whole
point of the language.

That reading conflates two things.

**The resource's state** — its type, its current phantom, its outstanding
obligations — must be live at runtime. There is no way around it: the fragment
arrives after compilation of everything else has finished, and nothing else knows
what `542fab` is.

**The code acting on that resource** carries no such requirement. A fragment can
be typechecked against a *manifest* of the bridge's handles and then **compiled
to native**. What conversation actually demands is that the **type context be
transportable**, not that execution be late-bound.

An interpreter is one way to get late binding. It is not the only one, and it is
the expensive one.

## Why this is unusually available here

Koru's compiler is metacircular, so it is already present wherever Koru runs —
there is no "the far end has no compiler" problem in the normal case. And `--ccp`
already exists to answer compiler questions to a non-human consumer, which is
structurally the same act as answering "what is `542fab`, and what may I do to
it."

The vocabulary a handle affords is likewise not new machinery: it is the set of
tors accepting the handle's current phantom state, which is exactly what
discharger discovery already computes (`690_056` closes a still-live file at
store teardown via a discovered discharger, hardcoding nothing). It has simply
never been asked at runtime.

## The cost lands in the right place, and that is the real argument

A runtime type system smeared across every value would be fatal to the thesis.
A manifest is not that. **You pay per handle parked on the bridge, not per value
in the program** — ten million values and three handles costs three.

That is the same bargain D7 already ruled for the store's identity question:
*"the index it needs is a DECLARED cost."* So this is not an exception carved out
of the no-runtime-cost tenet; it is the tenet applied. **You pay for what you
declare, and a session that wants to be resumable declares that it wants to be.**

## What this dissolved, and what it did not

Metering was the one requirement that argued for the interpreter as
*architecture* rather than fallback — arbitrary native code cannot be cheaply
metered. Metering was then **parked** (Lars, 2026-07-31: it only really makes
sense on a public-facing API, not on an internal bridge), so the argument is
moot rather than answered. Had it stayed, the likely resolution was a compile
profile inserting budget decrements — a comptime transform, which is native
work here — rather than an evaluator. **Untested, and now unneeded.**

The interpreter's honest remaining role is the fallback for when there is no
toolchain at the far end. Real, but not the shape of the system.

## Open

- No manifest exists. Everything above the `--ccp` and profile checks is design
  reasoning, not measurement.
- Whether the manifest is minted by the bridge or by the resource's type is
  unruled, and it decides whether two bridges can talk without a shared
  namespace.
- `shm` was floated for the co-located case. It solves *access*, not
  *permission* — the manifest is still what says a fragment may act — so it
  looks like a same-machine optimisation rather than the architecture. Unruled.
