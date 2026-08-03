# 410_011 — opaque procs and the limit of purity

**TODO pin, deliberately empty until the surface is designed. This note exists
because the gap became load-bearing on 2026-08-03 and a bare marker did not say
why.**

## What the cluster proves today

The purity checker reasons about Koru-level flows and it works: nine green pins
cover annotation (`410_008`), the unannotated default (`410_009`), transitivity
in both directions (`410_014` pure, `410_016` impure), event purity inferred
from its implementation (`410_007`/`410_015`), and module-crossing
(`410_017`).

## What it cannot reason about, and why that now matters

A `~proc |zig` body is an opaque `Source` string. The checker cannot see what it
touches, so `[pure]` on one is **declared and trusted**, never verified.

That was an acceptable hole while purity only informed test mocking. It stops
being acceptable the moment purity is asked to underwrite **automatic
parallelism**, which is the direction the store is heading (`DESIGN.md` ruling
(h): *"contracts ARE the threading proof"*; O7; `690_123`, whose header calls
itself "the baseline a disjointness-proving scheduler must preserve").

The store side of that proof is in better shape than this side. A standing
rule's footprint is bounded — `690_231` pins that writes do not transitively
fire the target store's rules, so no cascade closure is needed, and a
conservative literal-`<bind>.<field>` analysis covers every legal rule site in
the corpus. Cross-store disjointness is structural, since each store is a
distinct module-scope global. **The analysis terminates everywhere except
here.**

## The shape of the answer, not yet ruled

An opaque body cannot be proven pure, so the only honest options are to refuse
(serialize, never parallelize across one) or to let the author declare and be
trusted — which is what happens today, silently.

The lesson worth carrying in from the same day: a gate that fails conservative
is invisible. A parallelism gate that refuses on every opaque proc is *correct*
and could withhold parallelism from the entire corpus forever without a single
test noticing, exactly as a substring-matched removal gate withheld
vectorization for weeks. **Whatever is built here needs a test that asserts the
fast path was TAKEN, not merely that the slow path was correct.**
See `concepts/frag-a-gate-that-fails-conservative-is-invisible.md`.

## Why this pin stays empty

The refusal-vs-declaration fork is unruled, and inventing a spelling before the
workload asks is the failure this corpus keeps recording. The pin gets an
`input.k` when a benchmark needs parallelism badly enough to name what it wants.
