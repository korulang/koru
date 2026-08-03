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

## Open

Where the line falls when dimensions are genuinely runtime. Nothing in the
corpus needed that, which is itself suspicious — it may mean the workloads are
unrepresentative rather than that the case does not arise. A container sized
from parsed input is the obvious shape, and it would need either a first-class
escape hatch or a declared maximum with an exhaustion branch, which is the
answer the store already gives for capacity.
