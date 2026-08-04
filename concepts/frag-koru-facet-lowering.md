---
type: belief
id: frag-koru-facet-lowering
provenance: introduced by 69704130 — create(frag-koru-facet-lowering): the |koru facet ruling joins the in-repo corpus
ts: 2026-07-05
---

# Template lowering targets are languages, and Koru is one of them (belief)

A Koru template proc's facet tag names the **language of its rendered text**.
`|zig` renders Zig, `|js` renders JS, and — ruled 2026-07-04 — `|koru`
renders Koru source, which is parsed by the real parser into AST nodes and
never spliced as host text. Comptime contexts select the `|koru` facet; the
comptime interpreter evaluates the parsed rendering. This is distinct from
`|ast` by design: `[transform]` procs construct nodes programmatically,
facets render languages — two mechanisms, two names.

Corollaries held with it:

- The proc-head shape is `~[template] proc name|koru`: the consumption mode
  lives in the annotation (beside `[transform]`), and the pipe path is
  name|target only. The older `~proc name|template|zig` spelling predates
  this.
- The full loop this opens: comptime Koru computes → data → Liquid renders →
  Koru source → parsed AST → interpreted or emitted. The input side (values
  crossing into Liquid context) is the data→Liquid bridge; liquid.zig and
  parser.zig are already compiled into the Stage-C backend, so the bridge is
  Value-marshalling, not new machinery.
- A construct authored only as `|koru` is target-independent — every backend
  emits it through the normal pipeline. The north-star application is
  PGO-shaped lowering (Orisha route dispatch reordered from profile data at
  compile time).
- Facets are NOT a `|template`-only mechanism. A `[comptime|transform]` proc
  carries the same per-target facet variants: the std/io print family renders
  `print|zig` → a Zig posix.write, `print|js` → `process.stdout.write(...)`,
  and the build target selects the variant exactly as it does for a template.
  A transform stores its rendered text as the *invocation's* `inline_body` (and
  reroutes the call to a `.impl` stub for shape-checking); the emitter must
  splice that inline_body **wherever the invocation appears** — a nested `~if`/
  `~for` branch or effect-handler body, not only a top-level flow — or the
  nested site lowers to a dead call on the stub. A comptime|transform tor is
  therefore NOT target-agnostic: a target with no variant, or an emitter that
  splices only at top level, silently breaks that target (JS printing was fully
  broken this way until both halves landed). Pins: 010_008, 140_014, 630_001,
  630_005.
- Deliberately open, not part of this belief: surface spellings for the core
  nodes (foreach/conditional/assignment) and the fragment/AST-as-value
  surface.

Prior state this extends (was valid, now grown): template lowering was
host-text-only, template-ness lived in the pipe path, and the facet rule was
framed around `|template`/`|koru` procs — the comptime|transform print family
and the emitter's obligation to splice a nested transform's inline_body were
outside it.

Provenance: session INTERPRETER 2026-07-04/05 (Lars + Claude); pins
310_099/310_100 @e478834a, 310_101 @1ab16a7. Migrated from koru-membrane
frag-0001@c4db2bf when interlock v2 established the in-repo corpus.
