---
type: belief
id: frag-multicast-is-group-shape-not-declaration
provenance: session 2026-07-25 (Lars + Claude) — gallery/shader_toy tick arms silently dropped
ts: 2026-07-25
tags: [effects, KORU053, multicast, proxy, taps]
---

# Multicast is group shape, not a declaration the tor makes

**Considered and rejected:** a `[multicast]` annotation on the branch decl, so a
tor declares how its handlers compose. It is the natural-looking move —
`ast.Branch` already carries `annotations`, and "semantics follow the tor" is how
optionality works. We are not doing it.

**Why it fails:** the tor cannot observe fan-out. Presence is a genuine two-way
contract — the tor declares `?`, the consumer installs or omits, and the tor
reads it back in guard position (`if(arm)` → `@hasDecl`, see
[[frag-presence-effect-arm-expressions]]). Multiplicity has no return path. A
producer fires `tick(ms)` once; whether that lands on one body or five is decided
entirely handler-side and is invisible to the firing code. `[multicast]` would be
write-only decoration describing how *someone else's* arms compose — a different
and shallower thing than the presence contract it would be imitating.

## What the real defect was

Not a missing capability. **One spelling with two meanings:** an unguarded
`! name` is *a subscriber* when every sibling is unguarded, and *the fallback*
the moment any sibling carries a `when`. Position then silently decides which.
The trap is compiler-induced — KORU050 instructs you to add an unguarded arm, and
where you put it determines whether your other arms are emitted at all. Pinned
and walled: `400_174` / KORU053.

## Void-only multicast is already law

`emitter_helpers.zig` gates multicast on `resume_type == null and
resume_arms == null` — void only, the same constraint `std/taps` carries
explicitly (a tap inserts a *void* call). This was enforced but unwritten. It is
the mechanical form of the open edge in
[[frag-effect-unguarded-multicast]]: multicast of resume values has no coherent
join, so the compiler refuses to invent one.

## The shape that would resolve it, when something needs it

`ping-iter` (Lars): rather than folding N subscribers into one `fn` with one
return, synthesize an iterator over the subscriber set and let the producer
invoke each and handle its outcome arms. The reduction policy stops being a
declaration and becomes ordinary continuation structure — first-wins,
all-must-agree, short-circuit — expressed where the type information lives.

Two properties make it tractable rather than a research project. The subscriber
set is **comptime-known** (it is the emitter's group list), so it unrolls to
inlined calls — no runtime dispatch, no first-class effect values, no
type-system change. And it belongs in a **transform**, not the emitter: today's
fold rule lives in Zig-emission and works around a Zig constraint (one `fn` per
struct member name), so it is backend-specific by construction. Resolved at AST
level it lands once for every backend.

**Trigger to build it:** two independent subscribers wanting *overlapping* guards
on one arm, or anything needing to observe multiplicity. Neither exists yet;
every arm set in the corpus that looked like it wanted fan-out has disjoint
guards, which exclusive-first-match already serves. Until then this is
well-posed and parked, not half-built.

## The proxy asymmetry (do not generalize across it)

`Module(name) ! arms` is one spelling over two different composition contracts:

- **`std/store(name)`** — a `[pre]` rewrite to `watch`, splicing per site into
  the write subflow. Sites are independent; multicast is structural and
  order-free. This is why store never had the bug.
- **`koru/vaxis(name)`** — arms splice into the *same* `__H` fan-in
  ([[frag-vaxis-named-pump-attach]]). Same branch name at two attach sites means
  one group, so the exclusive rules apply across sites and the arms may be
  arbitrarily far apart.

Learning the store idiom and carrying it to vaxis produces exactly the silent
drop above, at longer range. The proxy is right for locality and worth keeping —
but "attach sites fire separately" is true of store and only conditionally true
of vaxis.
