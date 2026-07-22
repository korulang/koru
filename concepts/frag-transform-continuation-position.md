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

## Not the same class as the store nested-query wall

The memory baton `nested-transform-lowering-gap` over-unified this with the
nested `std/store:query` "unknown store" failure. They are DIFFERENT mechanisms:
the store case is a STANDING-RULE INSTALLATION that is top-level-only BY
CONSTRUCTION (ruled: [[frag-store-verb-placement]]), a message-quality pin
(690_066), not a lowering bug. This frag is the transform-pass mechanism only.
The shared surface is the SYMPTOM ("top-level-only") and the doctrine (teach it
at the koru level), never one root.
