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
two passes, composition is where they diverge.** The worked (now-fixed) instance:
the duplicate-branch-handler check (SHAPE002) lived independently in both
`shape_checker.zig` and `flow_checker.zig`; the inline `|>` chain and the
multi-line equal-indent `|>` continuation are the same construct, but the
multi-line path misparsed as sibling branch handlers **under a branch handler**
(effect `!`, obligation `|`) while staying green at bare flow head — a divergence
invisible to any single-feature test and visible the moment the two forms sit side
by side under the same context. It was fixed by *unifying* the two checks
(`d78e612a`, "unify branch/continuation validation"); the multi-line pins are now
green fix-locks. The lesson outlives the fix: a check implemented twice is a
standing invitation for composition to expose the drift.

The two failure directions this surface produces:
- **False reject** — a legal composition rejected (often with a *swallowed* or
  host-level diagnostic, never surfaced at the koru level). The multi-line-`|>`
  misparse above was this kind, now closed.
- **False accept** — a composition silently miscompiled: an invariant each
  component enforces alone goes unchecked once the two are nested, and the bad
  state leaks silently. This is the more dangerous kind, and the **live**
  exemplar: `330_098` — an obligation carried in a record field, dropped inside a
  `for ! each` body, leaks with no KORU030, though both components
  (`330_096` field-level, `330_053` for-loop escape) catch it alone.

Evidence lives as runnable pins, referenced by name (never restated here — they
move): the `670_NESTING_SWEEP` grid; the `220_017/220_020/220_024` multi-line-`|>`
fix-lock trio (green); the `330_098` false-accept (live). The standing generator
that farms this surface is `challenges/007_combinatorial_composition.md`; its
oracle is **compositionality** — if A is legal and B is legal, A∘B is legal and
means the obvious thing unless a *stated rule* forbids it, in which case the
rejection must carry a correct koru-level diagnostic.
