---
type: belief
id: frag-an-obligation-is-a-liveness-interval
provenance: Lars proposed store sets with compile-time-provable non-overlap, and named the obligation as the mechanism; this is what fell out when the consequence was followed — the strongest single result of the 2026-07-30 kernel/store conversation, and none of it is built
ts: 2026-07-30
---

# An obligation is not only a safety device — it IS a liveness interval, and that hands you an exact allocator (belief)

Obligations were built to answer a safety question: something is held, something
must discharge it, and the checker will not let the program forget. The whole
apparatus is described in the vocabulary of preventing a mistake.

Read it the other way and it is a different object. An obligation has a mint site
and a discharge site, and everything between them is where the thing it names is
live. That is an **interval**. Liveness — normally a dataflow analysis, and the
expensive prerequisite for any storage-sharing scheme — is therefore already
decided at compile time, by machinery that ships, for a reason that had nothing
to do with memory.

## Why the shape of the discipline matters, not just its existence

Obligations discharge LIFO. That is not an implementation detail here; it is the
whole result. LIFO nesting means the intervals form a **laminar family** —
properly nested or disjoint, never partially overlapping.

Two consequences follow, and they are not small:

- A laminar family is an interval graph, and interval graphs colour **optimally**
  by a greedy left-to-right pass. The packing problem that is NP-hard in the
  general case is exact here. Not a heuristic that is good enough; the actual
  optimum, in linear time.
- Peak footprint becomes **computable rather than measured** — the maximum
  simultaneous nesting depth, weighted by what each level holds. A number the
  compiler can state, not a number you discover by running out.

**The durable claim: a discipline adopted for safety can hand you an
optimisation for free, and the gift is invisible until you ask what the safety
artifact IS rather than what it PREVENTS.** Every description of obligations to
date is a description of what they stop. None of them would have led anyone to a
memory allocator.

## What the shape cannot absorb

A thing belonging to two SIBLING intervals has a liveness that is a union of
disjoint intervals, which is not an interval. That breaks laminarity, and with it
the optimality. It is also exactly the case where addresses must stay stable
across a switch. Both are answered the same way: place the shared members first,
at fixed positions, and pack the exclusive ones around them. Placed once, never
moved — stability by construction rather than by an invariant someone maintains.

Recursion breaks the bound outright: a held obligation inside a self-call has no
statically known nesting depth, so the exact peak stops existing. That should be
refused rather than analysed. It is the one wall the exactness claim has to stand
on, and buying exactness with a refusal is the better side of that trade.

## Where the risk actually is

Not soundness. **Diagnosability.** When a packing fails, the error must name a
program-level cause — these two things are live together here, and this grouping
assumed they were not — rather than an internal one about colourings and
conflicts. Register allocators are famous for failing exactly at this seam, and
the failure is not that they are wrong but that nobody can act on what they say.
That diagnostic is worth designing before the allocator, because it is the part
that decides whether the feature is usable.

## Why this closes a hazard rather than opening one

Sharing storage between corpora looks like it destroys the aliasing guarantee
that two separately-declared corpora cannot overlap. It does the opposite, and
this is the part worth remembering: **the allocator only ever overlaps things
that can never coexist.** So "shares storage" and "can be simultaneously live"
are complementary by construction, and if two are both reachable at a program
point they provably do not overlap.

The guarantee comes back derived from the same analysis that permits the
overlap, instead of assumed from an accident of code generation. Strictly
stronger than what exists now. The mechanism that appears to create the hazard is
the mechanism that eliminates it.

## Open

- How activation attaches the obligation. Lexical scope is not enough — it breaks
  at a call boundary, which is precisely what an obligation survives. The
  spelling is Lars's.
- Whether the structural rule (every operation downstream of a switcher) is a
  declarative shape law or custom analysis. Shape laws cannot see arguments, so
  identity must ride on the obligation regardless; the split is forced by the
  instrument, not chosen.
- Whether the switcher is itself an instance of the state-machine library rather
  than bespoke. See [[frag-synthesized-phantoms-are-derived-names]].

Related: [[frag-a-kernel-pass-must-not-fire-the-store]], `frag-store-verb-placement`.
