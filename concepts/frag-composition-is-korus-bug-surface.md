---
type: belief
id: frag-composition-is-korus-bug-surface
provenance: introduced by challenge(007) — Combinatorial Composition, first fleet
ts: 2026-07-20
---

# Composition is Koru's primary bug surface, because features share analysis machinery (belief)

In a conventional language features are **orthogonal**: a loop, a `try`, and a
struct literal each own a separate parser production and a separate, isolated
type-checking codepath. Nesting them is uninteresting because no shared invariant
spans them — the combination is free, and nobody writes a "combine your syntax"
fuzzer for C because it would find nothing.

Koru's thesis puts **control flow into the type system**, and the consequence is
that Koru's constructs are the opposite of orthogonal: effect branches,
obligations, phantom `<state>`, captures, pipelines, bare-return, subflows,
store-watch arms all thread through the **same** shared machinery — the flow
checker's model of *what threads through a point*, the phantom checker's
namespace/obligation tracking, the metacircular pipeline. Composing feature A with
feature B therefore exercises an interaction *inside* that shared machinery that
neither A-alone nor B-alone ever reaches. **That is why Koru's bugs live in the
combinations, not the components** — and why a combinatorial challenge is
warranted here where it would be pointless elsewhere.

The sharpest instance of the mechanism: **when the same check is implemented in
two passes, composition is where they diverge.** The duplicate-branch-handler
check (SHAPE002) lives independently in both `shape_checker.zig` and
`flow_checker.zig`; the inline `|>` chain and the multi-line equal-indent `|>`
continuation are meant to be the same construct, but the multi-line path misparses
as sibling branch handlers — a divergence invisible to any single-feature test and
visible the moment the two forms are placed side by side under the same context.

The two failure directions this surface produces:
- **False reject** — a legal composition rejected (often with a *swallowed* or
  host-level diagnostic, never surfaced at the koru level).
- **False accept** — a composition silently miscompiled: an invariant each
  component enforces alone (e.g. an obligation must be discharged) goes unchecked
  once the two are nested, and the bad state leaks silently.

Evidence lives as runnable pins, referenced by name (never restated here — they
move): the `670_NESTING_SWEEP` grid; the `220_017/220_018/220_019` multi-line-`|>`
false-reject cluster; the `330_098` obligation-in-record-field-under-for-each
false-accept. The standing generator that farms this surface is
`challenges/007_combinatorial_composition.md`; its oracle is **compositionality**
— if A is legal and B is legal, A∘B is legal and means the obvious thing unless a
*stated rule* forbids it, in which case the rejection must carry a correct
koru-level diagnostic.

Open question this belief deliberately does **not** settle: whether the
multi-line equal-indent `|>` continuation is itself legal Koru surface (make it
compile) or should be rejected-with-a-good-diagnostic. That is a live design
ruling for Lars; this fragment holds only the *why composition is where we look*,
not the direction of any specific pin.
