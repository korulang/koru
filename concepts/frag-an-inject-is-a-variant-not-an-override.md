---
type: belief
id: frag-an-inject-is-a-variant-not-an-override
provenance: designed in the twelve-dollar challenge session (Lars + Devin,
  2026-11-04) — replacing the earlier "compiler override pass" sketch after
  discovering the variant axis and cross-module impl machinery already exist
ts: 2026-11-04
tags: [koru, inject, variants, cross-module, lean-builds, design]
---

# An inject is a variant arm declared in a foreign file, not an override (belief)

The lean-build experiment on Orisha (capability-gated `ConnState`, pool dims,
accept fallback — ~3KB/conn vs ~10KB on the $12-server kernel) was held
together by `~proc`-level `if ($mod.CAPS.x)` seams edited into pump.kz. The
desired end state: `import orisha; import orisha/lean` — the lean composition
lives entirely outside the library it reshapes.

First sketch was a bespoke override pass (`[build(lean)]mod:tor = ...`).
Discarded: the compiler already owns two machines that compose into the same
thing — `is_impl` (cross-module impl pairing, `~mod:tor = ...`, home tracked
separately from qualifier; pins 430_014/015) and `impl_variant` (a `|tag` on
an impl arm, symmetric with `~proc foo|variant`). The feature reduces to a
new pairing contract on existing walks:

    import std/inject

    [inject]orisha:drive|lean { ... }

- **Opt-in twice, by design.** `import std/inject` is the declaration (a file
  announcing it contains inject arms); `--allow-inject` is the toolchain
  authorization. Without the flag, koruc refuses with a teaching message —
  injects replace another module's code and are intentionally brittle.
- **`is_inject`, not `is_impl`.** An impl pairs against a declared abstract;
  an inject adds a variant arm to a concrete tor. Same custody/home walk,
  different contract — separate flag so diagnostics can tell them apart.
- **Struct variation is free at proc granularity.** Zig-space declarations
  (`ConnState`, pool dims) nest inside `~proc` bodies; a `|lean` proc body
  carries its own struct, shadowing the module one lexically. The objection
  "a second ConnState collides with the first" dissolves — Zig scoping keeps
  them distinct, and `~proc`-spliced helpers resolve names at the splice
  site, so `growReqBuf` sees whichever `ConnState` is local. Helpers bound
  as real Zig fns against the fat type name their own leaks as type errors.
- **Single variant axis is enough.** `--build=lean` selects `|lean` instead
  of `|io-uring` — enumerated, mutually exclusive. Multi-axis selection
  (`--build=io-uring,lean`) is a named non-goal until a second orthogonal
  dimension appears; lean is a whole alternative body, not a layer.
- **Unresolved:** whether the parser accepts a qualified-variant spelling
  (`mod:tor|v`) on the proc path — the colon+pipe composition was reasoned
  from `impl_variant`'s existence on Flows but never compiled; proc bodies
  resolve through a different node path than Flow impls. First test belongs
  in the 430 cluster: `~lib:greet|lean` declared in a second file.

## What deliberately stays out

- No "callback to original" — injects shadow, they don't wrap. Wrapping
  rots the overlay into a second type system.
- No interface contract between base and inject — intentional brittleness,
  fail loud at Zig compile (leaked type mismatches name the site).
- No struct/type-decl injection — if a lean needs a different *type
  declaration*, the granularity question reopens; at `drive` granularity it
  hasn't needed to.

Evolution: what would correct this — if `std/caps` lands its comptime
capability gathering, injects become *capability declarations* instead of
variant arms: the caps walk reads the post-inject tree and proto synthesizes
against what it finds. Ordering contract is mandatory: inject resolution
must precede the caps walk, or caps inventories symbols about to be
replaced.
