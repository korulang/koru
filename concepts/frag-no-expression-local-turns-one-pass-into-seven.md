---
type: belief
id: frag-no-expression-local-turns-one-pass-into-seven
provenance: porting Unity DOTS BoidSystem.cs into the ECS surface benchmark 2026-08-03; the steering pass came out as seven chained writes over the flock where the C#, Zig and Rust arms each hold one expression, and the three arms still agree bit-for-bit
ts: 2026-08-03
---

# A missing expression-local binding is not verbosity, it is a different algorithm (belief)

The store has no way to name an intermediate inside an expression. The obvious
reading of that is a readability complaint — you repeat a subexpression, the
optimizer commons it, move on. That reading is wrong, and the boids port is
where it broke.

A steering step computes four vectors, sums three of them, branches on the
fourth, and normalizes twice. In C#, Zig and Rust that is ONE pass over the
population: the intermediates live in registers and never have a name outside
the loop body. In Koru they cannot live in registers, because there is nowhere
to put them, so each one becomes a COLUMN and the pass splits into seven chained
writes over the whole flock.

**The shape of the computation changed, not its spelling.** Seven traversals
where the borrowed algorithm has one is an algorithmic difference that any
profiler would report as a memory-traffic problem and no reader of the source
would recognise as caused by a missing binding form.

## Why this is worth believing rather than just fixing

Two things followed that were not predictable from "we lack local bindings".

**It was survivable.** Seven passes came within 1.21x of the hand-written
striped baseline that does one. The columns are hot, the layout is dense, and
the extra traversals are close to free next to the arithmetic. So the missing
binding is not an emergency — which is exactly why it could sit unnoticed until
a workload with a genuinely fat per-element expression arrived. Every scenario
before boids had a body small enough to inline without noticing.

**It has a name now.** Before this the store's known costs were about row access
— handles, resolves, guards. This is a cost about EXPRESSIONS, and it is the
first optimisation in this area with an obvious mechanism attached: an
expression-local binding collapses the seven passes into one, and nothing about
the store's design forbids one.

## The general form

When a language omits a way to name something, look for what the omission does
to the STRUCTURE of programs written in it, not to their length. The workloads
that reveal it are the borrowed ones: code written by people who had the feature
and used it without thinking, so the shape of their solution encodes the
assumption. A workload written natively would have been designed around the
absence and would never have shown it.

This is the second time the benchmark has produced a finding of that kind — the
first was a spatial index, which the store also could not express and which
turned out to want a second table rather than a bigger store.

## Open

- Whether an expression-local binding is a store feature or a language one. It
  reads like a language one, which makes it larger than it first appears.
- Whether the seven-pass shape is even the right thing to optimise. The
  alternative reading is that a fat per-element expression wants the kernel,
  not the store, and this workload is evidence about where that boundary should
  fall. Nothing here settles it.
