---
type: belief
id: frag-presence-effect-arm-expressions
provenance: introduced with the presence-expression implementation — feat(effects): if(arm)/when arm resolve at analysis+splice, KORU130/131 walls (400_146–400_150); evolved 2026-07-19 with the invocation-contract split surfaced by koru-libs vaxis (400_168)
ts: 2026-07-19
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

## Presence has TWO lowerings, one per emission path (833)

`@hasDecl(__H, "arm")` is the lowering only on the LEGACY Handlers-struct-fn
path, where `__H` is a real comptime param. When a flow-bodied event is folded
via the in-flow-scope INLINE SPLICE (832 — so the caller's mutable accumulator
stays in scope), there is no `__H` — that boundary is exactly what the splice
dissolves. There, presence resolves from the CALLER's installed continuations
(`ctx.inline_fire_conts`, codegen-time knowledge of what was installed) to a
comptime `true`/`false`. Same presence truth, two backends: a `__H` lookup
where a handlers struct exists, a caller-conts lookup where it doesn't. Both AST
`if`/`when` guards (`presenceConditionRewrite`) and template-baked `~if` →
`@hasDecl(__H, ...)` (`rewriteInlineHasDeclPresence`) take the conts backend on
the inline path. An event declaring an optional arm therefore no longer bails
out of inline-splice eligibility (833: fold × optional arm).

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

## The handlers struct carries only what the consumer wrote

Resolved (Lars-ruled 2026-07-12, pinned 400_154): the consumer's comptime
handlers struct contains ONLY handlers the consumer actually installed —
no synthesized stand-ins — so `@hasDecl(__H, ...)` IS the presence truth
for every arm kind. The 210_076 contract ("unhandled optional void fires
are no-ops") moved to the FIRE site: a void optional fire emits under a
comptime `@hasDecl` guard that folds to nothing when the handler is
absent — the same zero cost the inlined stand-in had, without the lie. A
synthesized no-op in `__H` was indistinguishable from a real install and
sent `if(<void arm>)` down the wrong branch for every omitting consumer.

## PRESENCE is consistent across paths; INVOCATION is not (400_168)

The section above establishes that *presence truth* resolves the same on both
lowerings (`@hasDecl(__H, ...)` vs caller-conts). But the way a `|zig` proc body
*invokes* a YIELDING optional arm does NOT — the two paths expose incompatible
contracts, and the consumer's branch shape silently picks which:

- **Handler-call path**: the arm is a nullable fn-pointer alias
  (`emitOptionalArmNullableAlias`), so the body must write `if (ready) |f| f();`.
- **Inline cut-1 splice**: no alias is bound — the rewriter lowers only DIRECT
  calls (`ready(...)` → splice marker, or evaluate-and-discard when unhandled).
  The nullable-unwrap form has no `ready` local in the spliced frame and leaks a
  raw Zig `undeclared identifier`.

So the "proc side gets a nullable fn-ptr alias" claim above is **handler-path
only**. It reads as universal solely because 400_148's arm is *resuming* (`-> T`),
which is permanently call-path (inline cannot express a resume value) — a yielding
arm that reaches the inline path breaks under the same body text. One body cannot
satisfy both paths; a guarded-only (catch-all-free) consumer is inline-eligible,
a guard-group / catch-all keeps the call path.

RESOLUTION (ruled + implemented 2026-07-19, "Option B"): a YIELDING optional arm
is a **callable** — the body calls it directly (`ready()`, `key(payload)`), and
`emitOptionalArmNullableAlias` binds it as an always-callable alias whose absent
case is a **producer-side no-op** (`else struct { fn __koru_noop(...) void {} }`)
— NOT installed in `__H`, so presence truth is untouched. A RESUMING arm (`-> T`)
stays nullable, because absence has no value to fabricate and you can't optimize
away a call whose result you need (400_148). One contract across both lowerings;
the body's spelling no longer depends on which path the consumer's branch shape
picks. It lowers to plain calls / comptime-folded no-ops — zero runtime machinery.
The earlier `procRefsOptionalArmAsValue` router is now inert (no yielding body
uses the value form); converting it into a koru-level diagnostic that teaches
`ready()` is a follow-up (Fable-plan step 3).

## Open questions

- JS target: presence should be native truthiness on the handlers object —
  unverified, designed for the Zig target first.
- **Follow-ups after Option B landed:** (1) convert the now-inert
  `procRefsOptionalArmAsValue` router into a koru-level diagnostic that teaches
  `ready()` when a yielding arm is referenced as a value (Fable-plan step 3);
  (2) harden the `|template|zig` pump alias site, which still assumes a third
  shape (step 4). Neither is required for correctness — Option B is complete and
  green.
