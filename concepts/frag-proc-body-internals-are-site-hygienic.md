---
type: belief
id: frag-proc-body-internals-are-site-hygienic
provenance: 2026-09-14 — koru-libs/asteroids-net: clock:ticks' `var __i` shadowed
  udp:packets' `var __i` when nested inlined (third collision in one session:
  raylib `i` × udp `i`, std/io print's `__f` param × raylib `__f`, then
  clock `__i` × udp `__i`)
ts: 2026-09-14
---

# Proc-body `__` internals are per-site hygienic — the emitter keeps the convention mechanically

An effectful `~proc|zig` body inlines into the caller's frame, opaque text and
all. Everything *named across* that boundary already got site-unique spellings —
event params (`__koru_arg_`), consumer branch bindings (`__koru_bind_`), result
temps (`result_e{d}_`), the proc label itself (`__koru_proc_{N}`). The one
surface nobody renamed was the body's **own internals**: `var __i`, `__f`,
`__p`, `__cap` — the author's "don't touch" namespace.

Two libraries independently writing `var __i` is not a naming mistake; it is
the inevitable consequence of a convention the emitter did not keep. Zig
forbids shadowing at function scope, so any nested composition of two such
procs was a compile error neither side could see coming.

The rule: in `rewriteEffectfulProcBody`, every `__x` token becomes
`__x_s{N}` where N is the splice's `proc_uniq`. `__` is a safe namespace to
rename uniformly because Koru bindings can't spell it and `.`-access is
boundary-excluded. `__koru_*` is excluded — that is the emitter's own
namespace, and generated code must stay resolvable.

The consumer side of the same frame: a consumer binding that would shadow a
plain producer local gets a site-unique `__koru_bind_` spelling (400_151 /
400_169). "The producer" means **every enclosing splice frame**, not just the
immediate one. A binding nested deep inside a spliced body (`! each i` inside
climb's `! pass`) still lands in the outer producer's Zig frame, next to that
producer's `|i|` capture (605_001, 230_026). The renames form a stack, not a
slot. An inner rename that masked an outer one used to send references to the
outer binding back to its raw name, and that read a producer's live local of
the same name: a silent miscompile, not a compile error.

Coverage is per *emission path*, and the stack only helps where the path
consults it. The rename reached AST expressions (`emitExpression`),
template-rendered body text (the inline-body rewrite), and guard text — but
not expression text lowered through `lowerExprZig`, which is where
`emitArgs` writes event payload values (`sink(c)` → `.handler(.{ .c = c })`).
A renamed binding's raw name then survived into the payload: undeclared
identifier when the producer scoped the name away (the koru-rive
`mesh_clip_event` `.c = c`), or — worse — the producer's live decoy local
when it happened to be in scope and type-compatible (`mtri(tv)` reading the
loop `|t|`; 230_033 prints `sink 7` for a payload of 42, 230_034 dies on
`use of undeclared identifier 'c'`). The rule stands: inside the splice
window EVERY reference to a renamed binding rewrites, and `lowerExprZig` —
the funnel for all Koru-expression text — is where that guarantee now lives.

What this does NOT cover, deliberately:

- **Non-`__` producer locals** (`var i` in a proc body) still collide with
  each other. The consumer-binding rename covers consumer-vs-producer at any
  nesting depth; producer-vs-producer on plain names remains a convention
  violation — `__` is the contract.
- **Consumer bindings other than splice-arm bindings** (chain-return `: v`,
  branch `| done d` of a nested call) are not checked against enclosing
  producer frames by this rule; `zig_scope_bindings` covers part of that
  surface for inline-frame params.
- **The JS emitter** (`emitProcBodyWithSplicedEffectCalls`) has the same
  class of hole and no equivalent pass yet.
