---
type: belief
id: frag-invariant-pure-steps-may-hoist
provenance: binarytrees autopsy → owned-value port → hoistInvariantLoopPrefix
  (d021044), 2026-10-25/26. Session error worth recording: the pure-tree shape
  was first declared inexpressible ("no recursive unions"); Lars corrected it —
  `grid` already proves data types are a library lane carrying chosen
  semantics, and avoiding them was posture, not a boundary.
ts: 2026-10-26
---

# Invariant pure prefixes of `for ! each` may hoist — the obligation system is what makes the question answerable (belief)

When a `for ! each` body's leading steps never read the item and reach no
`stored`/`captured`/io through their callee chain, the compiler may evaluate
them once before the loop. This is GHC's full-laziness move, but spelled
through machinery Koru already had, rather than assumed by a runtime:

- **Invariance is a dependence check** — no arg mentions the item or `__it`,
  AND no arg mentions a name the body writes. The second clause was missing
  until 320_183: a `capture … as g` cell is written per-iteration by
  `captured { … }` steps, so `bump(x: g.n)` named no item yet read the
  pre-loop snapshot when lifted — silent wrong-answer, printed 1 where 3
  was owed. The pass now tracks `as`-arm bindings as live cells for their
  subtree and treats any mention as variant.
- **Cleanliness is the same flood `[parallel]` runs** — same-module flow
  impls whose transitive callees stay clean, control builtins pass through,
  denylisted effect names stop the prefix. Recursion edges are `.visiting`,
  not dirty.
- **`<owned!>` mints are hoist-clean by ruling.** A mint looks effectful —
  it allocates — but an `owned!` return is a liveness interval
  ([[frag-an-obligation-is-a-liveness-interval]]), and its discharge is
  movable to the loop's `| done`. Mint…borrow…discharge once is observably
  the same as mint…borrow…discharge per iteration *when the produced value
  feeds only pure reads*; the obligation checker is what makes that claim
  decidable instead of hopeful.
- **The prefix, not the body, is the unit.** Item-dependent tails (`captured`
  folds, item-bound calls) stay in the loop untouched — `400_222`/`400_223`
  pin both directions, and `400_222` was verified to fail with the pass off.
- **Owned consumers hoist only on lifted inputs.** A step that consumes a
  `<!owned>` param may lift only when every such arg is bound by an earlier
  lifted step — `mint-node(l, r)` on loop-minted children is fine; `take(h:
  h0)` on an outer-scope obligation is not. Relocating an outer consume once
  *launders* the refusal the spelling must earn: 330_082 regressed red at
  first (hoist silently legalized an in-scope outer discharge, KORU032 lost
  its wall) until `ownedArgsLifted` closed it. Return-type `owned!` alone is
  not cleanliness — a move is not a mint.
- **A lifted binding the body still reads is a worker-environment input.**
  Under `[parallel]` the each body emits inside a worker fn: enclosing-scope
  consts are invisible *and* unshadowable across the namespace boundary.
  The hoist stamps the still-referenced lifted names as `@hoisted-env:`
  marks on the `for` invocation; the `~for` template passes them in and
  rebinds them under fresh names (`__koru_parenv_<n>`) inside `run`
  (400_224). Same law as capture cells: what crosses into a worker crosses
  as a parameter, never as a captured name.
- **Lane verbs declare their hoist contract on the verb.** The pass runs
  before transforms expand, so classification can't read the synthesized
  tor — it reads the lane spelling. `std/tree:dispose` is a consume;
  `std/tree:fold` reads a hoisted name and produces a value, clean by
  contract (`isTreeLaneVerb` is the shared door). What looked like a
  dispose-only workaround is now a protocol: any lane verb that reads,
  produces, or consumes under `for ! each` states its shape up front.
- **Arms that are a verb's own vocabulary travel.** `fold`'s `| node`/`| null`
  are spec, not control flow — `pre` carries whole continuations so the
  arms move with the step, and the arm bodies join the invariance scan
  (`| node n -> n.f + item` is variant). A named arm that isn't the lane's
  declared vocabulary still refuses the hoist.
- **Template renders baked before `.main` transforms are stale.** `capture`
  dissolves `captured{}` → `.assignment` at `.main`, after
  `process-template-procs` — so `[parallel]` cell partitioning only ever
  worked when auto-discharge's arm synthesis happened to force a re-render.
  Moving `capture` to `.pre` fixed that ordering but broke `listops`
  (dissolving before `stored`'s splice re-orders name visibility), so the
  landed fix is narrower: the inserter re-renders `[parallel]` bodies once,
  post-dissolve, under a `@par-rerendered` mark that keeps it out of the
  fixpoint.

## What it bought, measured

The owned-value binarytrees port — a `struct` + `mint`/`free-tree` obligations,
ordinary Koru, no arena — ran the unmodified Haskell-shaped source at ~2.8ms
down from ~482ms, checksum-identical, in Haskell's 1.8ms tier. The Haskell row
was never an allocator trick: `check (make 13)` is loop-invariant, GHC floats
it, call-by-need shares it. Koru can now make the same move where the spelled
effects permit it — and refuses silently-by-omission where they don't (the
item-bound or effectful prefix simply stays).

## The sharable belief

Two compiler capabilities — `[parallel]` partition legality and invariant
hoisting — are the same question wearing different costumes: *does this region
reach shared mutable state?* Koru's effect-spelling makes both transformable
*and* rejectable; languages without it choose between unsound motion and no
motion. Expect more passes to land here — the flood is the shared engine.

## What would correct this

- If allocation count ever becomes observable semantics (an allocator-
  pressure benchmark as a language contract), hoisting a mint changes
  observable behavior and the mint-cleanliness ruling is wrong, not just
  incomplete.
- If a `<!owned>` discharge can have drop-order effects (destructors with
  observable behavior beyond reclamation), moving it to `| done` is not
  observably identical.
- Non-`each` loops and arms that aren't a verb's declared vocabulary are
  still unhandled — widening, not correction, unless a case shows the
  refusal was wrong.
