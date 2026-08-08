---
type: belief
id: frag-a-gate-that-documents-its-own-removal-is-not-a-refusal
provenance: 2026-08-08 — found while designing automatic lock insertion at the Koru/host boundary. The design kept resting on "an impure implementation calls nothing"; Lars ruled that inline flows should be removed outright, and the survey found the construct already refused (KORU003) by a gate whose own comment describes removing it, with compiler unit tests grafting the construct in by hand to prepare for that landing
ts: 2026-08-08
---

# A gate that documents its own removal is a parked intention, not a refusal

A feature gate is usually read as a decision: this construct is not allowed.
That reading is wrong whenever the gate carries a note explaining how to lift
it. Such a gate does not record *we refuse this*; it records *we have not got
round to this yet*, and those two states differ only in a comment while being
opposite in consequence.

The distinction matters because of who reads it next. An unpinned wall is lost
to **accident** — a refactor moves the diagnostic and nothing goes red. A gate
annotated with its own removal is lost to **diligence**: the next reader finds
a rejection, a comment naming the rejection as the thing standing in the way,
a preserved implementation behind it, and unit tests already asserting the
machinery the feature would need. Everything visible says *finish this*. Opening
the door is not a lapse in that state; it is the obvious, conscientious move,
and the reader is rewarded for it by tests that pass.

So the honest question about a gate is not whether it currently rejects. It is
**what a competent reader would conclude the gate is for.**

## The instance

Inline flows inside a `~proc` body. A proc body is host text the compiler cannot
read, which is what makes an impure implementation a *leaf* — the whole reason
purity propagation can treat local purity as transitive purity for a proc with
no visible dispatches, and the reason obligation lifetimes are bounded at all.
An inline flow is the one construct that places Koru structure on the far side
of that boundary, which turns a leaf into an interior node and makes every pass
that reasons about what a call can reach unsound at once.

Lars ruled it out on the ergonomics rather than the mechanics, and the ruling is
sharper than the mechanics: the construct is a *comfortable* way to break the
core arrangement. A bypass nobody can find gets used by nobody. A bypass that
reads as a convenience becomes the default, and "the structure is Koru" degrades
from a property into a request.

The residue is a pin (210_204), not this file. What this file holds is the part
the pin cannot: that the door was **decided shut**, so the comment describing its
removal describes an intention that has been withdrawn. Delete that comment and
the tree contains no evidence a decision was ever made — which is precisely the
state that produced this fragment.

## Why this is not the tilde wall again

[[frag-tilde-marks-the-host-boundary]] ends on the neighbouring belief: a rule
enforced at one site with its diagnostic in one place is bounded by whoever last
counted the doors, and being unpinned is a defect in its own right. That case is
about **enumeration** — routes nobody counted.

Here the door was counted, closed, and correct. The defect is one layer up, in
what the closure *claims about itself*. A wall can be complete, single-sited,
working, and still be self-repealing, because it is labelled provisional. That is
a different failure with a different remedy: enumeration does not help, and
neither does a stronger check. The only remedy is stating the decision and
pinning it, so reopening costs a red test rather than a plausible afternoon.

The two beliefs meet at the general shape both are instances of: **a principle is
only as strong as the weakest artifact that records it**, and a comment promising
future permissiveness is weaker than no comment at all.

## What would correct this

A legitimate need for Koru structure inside a host body that a top-level subflow
cannot express — most plausibly a host-driven callback, where the host owns the
loop and must fire a Koru event per item. If that shape is real and has no other
spelling, the belief is wrong: the gate should open behind a designed surface
rather than stay shut behind a pin. Note the asymmetry that makes the pin the safe
bet anyway — removing a pin to land a designed feature is cheap and deliberate,
while an ergonomic bypass shipped by default cannot be withdrawn once written
against.

The weaker falsifier, worth watching for: if the pin's existence pushes anyone
toward reaching into the event system from inside host text directly, the
refusal has made a visible bypass into an invisible one, and that is worse for
every pass downstream. Nothing observed yet; Lars judged that route pathological
and nobody reaches for it.

Related: [[frag-tilde-marks-the-host-boundary]] (the neighbouring defect, by
enumeration), [[frag-a-gate-that-fails-conservative-is-invisible]] (a gate whose
*predicate* lies rather than its label), [[frag-an-obligation-is-unary-every-boundary-is-relational]]
(the boundary this one guards, from the type side).
