---
type: belief
id: frag-presence-effect-arm-expressions
provenance: introduced with the presence-expression implementation — feat(effects): if(arm)/when arm resolve at analysis+splice, KORU130/131 walls (400_146–400_150)
ts: 2026-07-11
---

# Presence expressions for optional effect arms (belief)

Inside the declaring event's impl, an optional arm's bare name in condition
position is a COMPTIME presence test — "did this consumer install the
handler". Two homes, one expression kind: `if(ask) | then | else` and
`when ask` guards (ruled 2026-07-03; pinned 400_146–400_150).

## The belief

Presence partitions CONSUMERS, not firings. Per consumer it is
all-or-nothing and statically known, which is why a `when <arm>` presence
guard counts as FULL coverage of the upstream branch — the 210_084/085
rejection of when-only handlers targets RUNTIME value guards, which drop an
unpredictable subset of firings. A presence guard's false case is exactly
the trajectory the `?` on the arm already blesses.

The lowering is `@hasDecl(__H, "arm")` — a real comptime bool, so the host
analyzes only the taken branch and the absent case never sees `__H.arm`.
The proc side gets the same information as a comptime-known nullable
fn-pointer alias (`if (ask) |f|`, 400_148).

## Why the two homes resolve at DIFFERENT layers

The `~if` template bakes its condition at render time (`{{ expr }}`),
upstream of every emitter rewrite site — so the if-home substitutes in the
template processor's per-call render, threaded with the enclosing flow's
impl-event context. `when` guards are the opposite: templates never bake
them; the guard text is written when the emitter resolves splice markers —
so the when-home rewrites at the splice guard sites. One expression kind,
two resolution layers, dictated by where each condition's text is born.

## The walls are koru-level, not host leaks

- KORU130: firing a value-resuming optional arm without a dominating
  presence test. No no-op can be synthesized (a fn with a mandatory return
  and an empty body is not a thing); a fabricated default would be a silent
  fallback. Dominance is a walk-scoped stack: the `then` arm of `if(arm)`
  and `when arm`-guarded subtrees establish presence — an `| else`-side
  fire is still walled.
- KORU131: presence test on a REQUIRED arm (either home) — exhaustiveness
  guarantees a handler, the test is a meaningless always-true; reject and
  say why rather than folding to true silently.

## Open questions

- VOID optional arms keep the 210_076 no-op contract (a synthesized
  `fn arm(_) void {}` in the consumer's handlers struct), and that no-op
  POISONS `@hasDecl` for the omitted case: presence on a void arm reads
  "installed" even when the consumer omitted the handler. Observationally
  silent for guards (the no-op does nothing), but an `if(<void arm>)`
  choosing between observably different terminals would take the wrong
  branch when omitted. Unpinned; candidate fix is moving the no-op from
  the consumer's struct to a defaulted alias on the declaring side so
  `__H` stays clean. Needs a ruling — the no-op contract is Lars's.
- JS target: presence should be native truthiness on the handlers object —
  unverified, designed for the Zig target first.
