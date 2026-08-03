---
type: belief
id: frag-second-class-is-what-makes-a-container-disappear
provenance: 2026-08-03 — a static, comptime-named grid was designed as a new construct before discovering std/grid already existed as a heap-boxed first-class collection; the two turned out to be one concept at opposite ownership models
ts: 2026-08-03
---

# A first-class collection and a second-class table are one concept, and the ownership model is the whole difference (belief)

The store was ruled second-class — comptime-named, never a runtime value — and
the argument recorded for it was about reactivity: watch compilation must know
which write path to splice at comptime. That reasoning is narrower than the
result. **Second-class-ness is what lets a container compile away, and that has
nothing to do with reactivity.**

A container held as a value must box its handle, allocate its backing, carry an
ownership obligation, and be addressed through a pointer nobody can constant-
fold. A container named at comptime has a known size, static backing, no handle
to box, no obligation to discharge, and an address the optimizer can see all the
way down. Same data structure, same layout, same operations — the difference is
entirely whether the program can *hold* one.

## The evidence, which arrived by accident

Two grids were written independently, months apart, without either author
knowing about the other. One is first-class and heap-boxed; one is second-class
and static. They are the same concept: a dense, positionally-addressed field of
cells. And the first-class one's own header names the box as its only
performance debt — a debt the second-class version does not incur, because there
is nothing to box.

The convergence is the finding. When the same structure is reached twice from
different directions and the versions differ only in ownership, ownership is not
an implementation detail of the structure; it is the axis the design lives on.

## What follows

- **When a container's dimensions are comptime-known, first-class-ness is pure
  cost.** It buys the ability to pass the container around, and a program that
  never passes it pays for that ability anyway.
- **The dividing question is not "is this reactive" but "must the program hold
  it".** A grid wants no reactivity and still belongs on the second-class side.
- **Two constructs that differ only in ownership should be one construct**, at
  the ownership model that costs less, unless a caller genuinely needs to hold
  one at runtime. Check the callers before assuming any does — the ones here all
  declared literal dimensions and never passed the container anywhere.

## The bill second-class-ness sends, which we did not see coming

Removing first-class-ness removes the handle, and removing the handle removes
the READ VERB along with it. That second deletion is the one that is easy to
miss, because nothing announces it: a first-class container is read by calling
something (`get(g, x, y): v`), and a call is resolved, typed and flowed by
machinery the language already owns, at every position an expression may stand.
A comptime-named container has no call to make. Its read is a piece of text that
has to be rewritten into an address, and the language will not do that for a
construct it has never heard of.

So the declaration has to own a whole-program rewrite: every guard, every
argument, every interpolation, everywhere. That is a strictly larger surface
than the verb it replaced, and it does not arrive with the write — the grid
shipped able to write cells and unable to ask what one held, which reads as an
oversight and is actually the shape of the trade. `std/store:new` already
carried exactly this pass for singleton cell paths, which is the tell: the first
second-class container in the language paid this bill too, and nobody wrote down
that it was a bill rather than an implementation detail of stores.

The consequence for the ledger above: second-class-ness is cheaper at RUNTIME
and dearer in the COMPILER, and the compiler cost is not proportional to the
construct — it is proportional to the number of syntactic positions the language
admits an expression in. That is a cost that grows with the language rather than
with the feature, which is an argument for the two containers sharing one
rewriter rather than each owning a lookalike.

## Open

Where the line falls when dimensions are genuinely runtime. Nothing in the
corpus needed that, which is itself suspicious — it may mean the workloads are
unrepresentative rather than that the case does not arise. A container sized
from parsed input is the obvious shape, and it would need either a first-class
escape hatch or a declared maximum with an exhaustion branch, which is the
answer the store already gives for capacity.
