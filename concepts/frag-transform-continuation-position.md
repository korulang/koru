---
type: belief
id: frag-transform-continuation-position
provenance: surfaced by the koru-examples APP_CHALLENGE fleet (chal-meta-exprlang continuation-position transform); diagnosed + diagnostic-wall built 2026-07-22 (pin 210_158, KORU124)
ts: 2026-07-22
---

# A whole-program transform can't compose in continuation position — the escape matches flow ROOTS, and the nested graft-back is short-circuited (belief)

A `[comptime|transform]` event invoked in **continuation position**
(`~seed(): v |> calc-fold { ... } | computed r |> ...`) fails where the SAME
transform composes fine at top level. The cause is NOT that the transform pass
skips nested positions — the walker DOES descend (`transform_pass_runner.walkNode`
recurses into continuations and reaches the site; the panic came through
`applyTransform`, not a missed visit). The cause is the **whole-program escape**:

- The runner is position-agnostic for **site-local** results: for a nested site
  it hands the handler a synthetic top-level VIEW of the site (`siteView`), the
  handler returns a `replacement`/`replacement_node`, and `spliceSiteResult`
  GRAFTS it back into the real holding continuation. This composes at any depth.
- A handler that returns `result.whole_program` (the legacy escape — e.g. the
  canonical `renderHTML`/`calc-fold` transforms that rebuild the program to add a
  synthesized runtime event+proc) SHORT-CIRCUITS that graft: `spliceSiteResult`
  returns the whole program verbatim. The handler's own rewrite matcher keys on
  `flow.inv()` — the flow ROOT — so on the synthetic view it rewrites the synthetic
  root copy, but the REAL continuation site (whose flow root is `seed`, not the
  transform) is never touched. The matching invocation survives, the circuit
  breaker's count doesn't drop, and it fires.

So: **whole-program-escape transforms are flow-root-only by mechanism.** Site-local
transforms already compose in continuation position; the escape does not.

## What was built (rung 1 of 2) — and why the message came first

The circuit breaker previously raised a raw host panic (`TransformDidNotReplace`
→ `@panic` in `koru_std/compiler.kz`), leaking a Zig stack trace with no `.kz`
location — and degrading into a secondary `union field 'Exited'` crash. That bad
message is itself the defect that lures the next builder into contorting their
code. The wall (KORU124): when the breaker is about to fire AND the site is nested
(`sr.wrapper == null`) AND the result used the whole-program escape
(`result.whole_program != null`), emit a located koru diagnostic naming the
constraint + the fix, and stop cleanly (`std.process.exit(1)`, since
`evaluate-comptime`/`run-pre-transforms` return a ctx with no error channel). The
detection is precise: root sites, site-local results, and genuine infinite loops
keep the old "Invocation not replaced" path. Board verified Broken:0.

## The capability rung (not yet)

Making it actually COMPOSE: for a nested site with a whole_program result, graft
the handler's rewrite of the synthetic view back into the real holding
continuation (keeping the appended top-level items), instead of returning wp
verbatim — OR migrate such transforms off the whole-program escape onto
site-local results. Then flip 210_158 MUST_FAIL→MUST_RUN. koru's own suite already
parks the sibling frontier at `210_024_source_scope_capture` (TODO, 2026-06-03).

## Third instance of the family — the FRONTEND checker (2026-07-23, building sweep)

The "nested transform loses its top-level treatment" pattern is NOT confined to
the transform pass. Building `std/store:sweep` (a transform in continuation
position — a `! draw`/loop-body read) surfaced the SAME shape in the frontend
flow_checker: the KORU100 unused-binding deferral was keyed on
`flowRootIsTransform` (the FLOW ROOT being a `[transform]`). A top-level `query`
gets its projection bindings deferred to `all` mode (usage invisible until the
transform runs); a nested `sweep` under a non-transform root (`for`, vaxis `run`)
lost that deferral and false-positived KORU100 on projection fields that ARE used
downstream. Fix: propagate the deferral to a continuation's BRANCH continuations
when that continuation's node is itself a transform/template
(`validateBindingUsage` now threads `root_transform or isDeferredBindingInvocation(cont)`)
— the nested-position twin of `flowRootIsTransform`. So the family now has THREE
confirmed members: the transform-pass circuit breaker (this frag), the store
top-level-only discovery ([[frag-store-verb-placement]]), and the frontend
KORU100 deferral. The general lesson holds: any pass that special-cases
"top-level / flow-root" position will mis-handle a nested transform until it
threads the same treatment down.

## Not the same class as the store nested-query wall

The memory baton `nested-transform-lowering-gap` over-unified this with the
nested `std/store:query` "unknown store" failure. They are DIFFERENT mechanisms:
the store case is a STANDING-RULE INSTALLATION that is top-level-only BY
CONSTRUCTION (ruled: [[frag-store-verb-placement]]), a message-quality pin
(690_066), not a lowering bug. This frag is the transform-pass mechanism only.
The shared surface is the SYMPTOM ("top-level-only") and the doctrine (teach it
at the koru level), never one root.

## A third member of the family: a site replacement that drops the chain TAIL

2026-08-04. `std/grid:stored` executes and then **silently discards every step
piped after it**. `697_012` pins it: the write lands, and the `|> print.ln`
following it never runs. No diagnostic, exit 0.

This is neither of the two above, and the distinction is the useful part:

- Not the whole-program escape. The grid handler returns an ordinary
  `.transformed.replacement`, the kind that is supposed to graft.
- Not the store's standing-rule wall. That one is top-level-only by
  construction and REFUSES. This one accepts and loses work.

What is lost is the holding continuation's TAIL, and the cause turned out to be
one expression in the handler rather than anything in the pass machinery:

    .body = ast.rootSite(call, &[_]ast.Continuation{}, flow.location)

The replacement was built with an EMPTY continuation list. `spliceSiteResult`
was never at fault — the handler threw the chain away before it got there.
Every `rootSite` call in `store.kz` passes the real continuations; the two in
`grid.kz` passed nothing, which is why only the grid had the defect. A write has
no branches of its own, so `flow.body.continuations` is entirely chain steps and
all of it belongs on the replacement. FIXED; `697_012` is green and covers both
the tail and two chained writes in a loop arm.

**Why it survived this long: every grid test writes in STATEMENTS, never in a
chain.** `697_001` established that form the day the grid landed and nothing
since had cause to deviate, so the entire corpus stepped around the defect
without anyone choosing to. A test suite can be uniformly idiomatic in a way
that hides a whole shape — the same blind spot as
[[frag-a-corpus-exercises-its-authors-idioms]], costing a correctness bug
rather than a coverage gap.

The store does not have it because it mints ONE unit per store and passes the
field as an argument, so a chained store write is an ordinary repeated call to
a shared event; `koru-libs`' `bounce.k` has chained two per entity for weeks. A
grid's unit carries the assignment itself and is installed per site.

**THE DECOY, AND THE ORDERING LESSON — the most transferable thing here.**
Inside a `for` arm the same chain failed LOUDLY instead: `duplicate struct
member name`, because the unit was keyed on the FLOW's line and every link of a
chain shares it. That looks like the bug. It is not; it is the drop, caught by
accident.

The key was uniquified FIRST, on its own, and it made the system WORSE — with
the tail still being discarded, the loop shape now compiled and silently printed
the wrong answer. **The collision had been the only thing making the drop loud
anywhere.** That change was reverted, the drop was fixed, and only then was the
key made unique; both are green now and `grid.kz` records the order at both
sites.

Generalised: **a symptom can be load-bearing while its disease is untreated.**
Fixing the noisy thing first is how a loud bug becomes a quiet one, and quiet is
strictly worse. Before removing a diagnostic — even an ugly one leaking from the
backend — establish what it is currently the only evidence of.

Cost, concretely: `koru-libs`' boids renderer drew a black window, because its
frame arm was `std/grid:stored {..} |> draw.rect(..)` and the draw was the
swallowed step. It needed no workaround in the end; the ordering rule that
working around it produced was pure accident debt.
