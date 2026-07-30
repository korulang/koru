---
type: belief
id: frag-synthesized-phantoms-are-derived-names
provenance: Lars asked whether phantom types have ever been synthesized and proposed that the state-machine library is where that belongs; checking the claim produced a sharper answer than either of us had — 2026-07-30, nothing built
ts: 2026-07-30
---

# We already synthesize phantoms — but only CONSTANT ones, and the derived name is the whole new capability (belief)

The premise that phantom synthesis has never been done is wrong, and the
correction matters more than the premise. A store that opts into entity identity
mints an obligation marker on a synthesized type; the author never writes it and
the checker honours it. The mechanism ships.

But every synthesized phantom in the corpus is a **constant literal**, written
into its library. That is not a small qualifier — it is the reason they are safe.
A constant is fully qualified, owned by one library, and cannot collide with
anything, so none of the questions that make name synthesis hard ever arise.

**What has never been done is deriving a phantom's name from what the author
wrote.** That is the capability, and the gap is both smaller and sharper than
"we have never synthesized phantoms": the machinery is proven, only the
derivation is new.

## Where the danger is, precisely

Phantoms compare as strings. Two machines with a state of the same name produce
the same phantom, and nothing in the comparison knows they came from different
places. A derived name has none of the protection a constant has.

This places derived-phantom synthesis in a class already identified and already
understood: a transform that MINTS A NAME which something else must resolve
later, which is the class that breaks at module boundaries while looking fine in
a single file. Several hand-rolled instances of that fault already exist, and the
remedy has been designed and never built — make the namespace **un-nameable**, so
the framework owns qualification and the author cannot spell it wrong because
they cannot spell it at all.

**So derived synthesis should be that remedy's first consumer rather than its
next instance.** The strong version of the claim: any new name-minting capability
built before the remedy is a decision to hand-roll the fault again, and it will
look correct until the declaration moves into a module.

## Why the state-machine library is the right home

It gives that library the job it has never had. The idea has sat with no
motivating consumer and deliberately no syntax; what it does is turn a set of
state names into two things at once — an effect-branch surface, and a family of
phantom obligations named for those states. Illegal transitions stop being
runtime checks and become type mismatches.

Grouped corpora are then an INSTANCE of that, not bespoke machinery. That is the
anti-fragmentation argument, and it is the reason to build the general thing
first: the alternative is not "less work", it is the same fault hand-rolled once
more.

## The de-risking move

Reproduce the existing constant phantom through the general machinery before
using it anywhere new. It ships, it is green, and a row's lifecycle is exactly
one small state machine. If the general design can reproduce known-correct
behaviour, it has been validated against something real. Debuting it on new
ground means debuting where nothing is known-correct and every disagreement is
ambiguous.

## The requirement that will be discovered late if it is not written down now

A diagnostic about a synthesized phantom must speak the **author's** vocabulary.
The standing rule — render the spelling the author typed — has no answer here,
because they typed a state name and got a phantom they never saw. Without a
rendering carried by the library, every diagnostic in this system reads as a
complaint about a type the author did not write and cannot find.

That is a harder version of the ordinary rule, and it is a design input rather
than a polish step: the mapping from synthesized name back to authored word has
to exist at the moment the name is minted, because nothing downstream can
reconstruct it.

## Open

- Whether the effect-branch surface and the phantom family are one declaration or
  two. Spelling is Lars's.
- Whether volume of synthesis is a real cost. Suspect not: the store already
  synthesizes many unit families per declaration, so scale is proven and only
  derivation is new — the same conclusion this belief reaches from a different
  direction, which is mild evidence it is right.

Related: [[frag-an-obligation-is-a-liveness-interval]],
`frag-transform-module-exposure-is-not-one-fault` (the fault class),
`idea_comptime_authoring_surface` (the unbuilt remedy).
