---
type: belief
id: frag-vocabulary-is-not-evidence-of-what-a-transform-emits
provenance: `koru_std/kernel` was written into a handoff commission as NEVER-PORT on the strength of its MLIR/GPU vocabulary; opening the file showed the GPU path is an opt-in call-site variant and all 30 blocked tests call it plain
ts: 2026-08-06
---

# A module's vocabulary is not evidence of what its transform emits

`koru_std/kernel` mentions MLIR 37 times and GPU 40 times, and sixty of those
sit inside one proc. A read-only scout concluded it was "the Kernel/MLIR/GPU
backend, a Zig-only province", and that conclusion was carried into a handoff
document as a permanent exclusion: **never port kernel**.

It is wrong, and the measurement that shows it takes about a minute:

- The MLIR/GPU lowering is an **opt-in call-site variant** —
  `std/kernel:self|mlir { … }` and `|mlir[gpu]` (`kernel.kz:355`, `757-783`).
- The compiler already refuses unsupported variants **loudly and by name**,
  KORU122 and KORU123, which is what a genuinely unportable surface looks like
  when it is handled properly.
- **All 30 kernel-blocked tests call it plain**, with no variant tag at all.
  `|mlir` appears in six files corpus-wide.
- The default lowering generates struct layouts and loop code from a shape
  declaration. Nothing about that is host-specific.

So kernel is a transform family exactly like `store`: it wants `|js` renderings
in its `.kz`, and only `|mlir[gpu]` stays correctly refused.

The belief this leaves us with: **for a transform, what the source TALKS ABOUT
and what the transform EMITS are independent, and grep density measures only the
first.** A comptime transform is a program that writes programs; its own
vocabulary describes the space of things it can emit, including branches nobody
in the corpus takes. Reading `mlir` sixty times says the module *can* emit MLIR.
It says nothing about whether the default path does, and the default path is the
only one 30 blocked tests use.

This is the same error as `frag-store-is-a-transform-not-a-runtime-library`
seen from the other side. There, size was mistaken for port cost; here,
vocabulary was mistaken for port impossibility. Both come of estimating a
transform from its surface rather than from what it lowers to, and a transform is
exactly the construct where surface and output are least related.

Two aggravating factors worth keeping, because they are procedural rather than
technical. The inference cited `JS_TARGET_SPIKE.md`'s Elm-shaped thesis as
authority — the **second time in one day** that document was treated as current
state when it was stale or misapplied. And the claim was propagated from a
read-only scout into a committed handoff **without anyone opening `kernel.kz`**.
A scout's report is a hypothesis; writing it into a durable artifact converts it
into a fact, and that conversion is where the verification belongs. Nobody caught
it until the human asked, simply, why kernel was on the list.

Open question: whether the `|mlir[gpu]` variant has a JS analogue worth wanting
at all. WebGPU and WASM SIMD exist, so "no GPU on JS" is not obviously true
either — but that is a language-surface decision about what the JS target is
FOR, and it belongs on a walk, not in a port.
