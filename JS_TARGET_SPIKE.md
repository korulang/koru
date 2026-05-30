# Koru → JavaScript target: spike spec & settled invariants

Worktree `js-emitter`. Goal: add `--lang=js` so the final emission step produces
`output_emitted.js` instead of `output_emitted.zig`. Merge back to main only if
the thesis below is demonstrated on **real emitter output** (not hand-modeled JS).

## STATUS

- **Phase 0 — plumbing slice: DONE + verified (2026-05-30).** `koruc --lang=js x.kz`
  → `output_emitted.js` (hardcoded stub), `node` runs it, no `.zig`/`a.out`, Stage D
  skipped; default Zig path unchanged. Changes: `koru_std/compiler.kz` (emit_zig JS
  branch), `src/main.zig` (compiler_env `lang`, filename, Stage-D skip, frontend run-skip).
  SEAM CORRECTION: the live backend *driver* is the NON-visitor branch of
  `generateBackendCode` (generated main() ~main.zig:969-989/1095), NOT
  `generateVisitorBackend` (:2911, only reachable via `--visitor`). But the user-program
  EMITTER is still `VisitorEmitter` run inside `emit_zig` (compiler.kz:1383) — that's
  where the real `JsVisitorEmitter` slots in, replacing the stub.
- **Phase 1 — real AST→JS emitter: DONE + verified (2026-05-30).** `src/js_emitter.zig`
  (~310 lines) walks `ctx.ast` and emits JS; wired into `emit_zig` (compiler.kz) when
  `lang=="js"`, replacing the stub. `koruc --lang=js _phase1/pump.kz` → real
  `output_emitted.js` → `node` prints `sum = 45`; AST-derived (n=10→100 propagates,
  prints 4950). Default Zig path unchanged. Emits the static-dispatch convention
  exactly: `handler(input,H)` for effect events, `handler(input)` for plain (the
  400_109 fix shows here — `report` gets no H), `Handlers_N` objects, `{tag,field}`
  unions, direct calls.
  KNOWN NARROWNESS (next-program surface): single bare-expression resume-value effect
  handler only; single-invocation/`_` terminal bodies only; meta-events
  (`koru:start/end`) namespace-filtered at emit; proc-body re-indent is flat (cosmetic);
  no taps/modules/comptime/sibling-or-guarded handlers.
- **Phase 1.5 — nested/void effect chains: DONE + verified (2026-05-30).** `js_emitter`
  now recurses: an effect handler whose body is an invocation builds a nested `Handlers_M`
  and calls it (void → no `return`; resume-value → `return EXPR`). `_phase1/chain_log.kz`
  (depth-3 nest, `! v _ |> mid ! v _ |> leaf ! v _ |> inc()`) emits nested static dispatch
  → `node` and Zig both print 27 lines (3³). pump.kz still `sum = 45`. This is the
  static-dispatch form of the "endless dynamic-dispatch chain."
- **OPEN — module-level state (design question for Lars).** `var counter` is dropped by the
  emitter, so chain.kz (counter variant) emits but throws `counter is not defined` at node.
  Decide: per-target top-level decls, or no mutable module state (Elm-shaped — thread it).
  Gates the counter-based chain benchmark.
- **Phase 2 — benchmark: DONE on real emitted JS (2026-05-30).** Host lines pass through for
  `.kjs` (module state works). Two receipts, Claude-verified:
  - chain.kjs (depth-3 nested, n³): koru-static ~8× faster than Node EventEmitter, ~1.5× off flat.
  - DEPTH SWEEP (pipeline, M=5e6, ns/hop): EventEmitter FLAT ~19 ns/hop across D=1..16 (V8 can't
    fuse dynamic dispatch — the structural floor). koru-static ~2 ns/hop, dyn/koru compounds
    8.0→9.5 through D=8, then DEGRADES to ~5× at D=16 (koru rises to ~3.7 ns/hop — V8 inline
    budget exceeded on the per-item nested `Handlers_K` closure tower).
  - FIX IDENTIFIED: emit-time textual chain fusion (Koru knows stage1→…→stageD statically →
    collapse nested handlers to straight-line, hoist closures out of the hot loop). Survives V8
    (unlike LLVM fold). The ceiling is the emitter's, not V8's.
- **Verdict: thesis validated on real output.** Worth pursuing. Next: emit-time fusion to hold
  ~2 ns at depth; framework-dispatch (signals) baseline; elide trivial arg-object allocation.

## The thesis (Elm-shaped, not transpiler-shaped)

Koru-on-JS is a **self-contained ecosystem that compiles to JS**, like Elm — NOT
a drop-in transpiler that slots into a React/npm app.

- JS is a dumb codegen backend, exactly like Zig is today.
- The JS module system / npm is an **FFI escape hatch at the edges** — same role
  C/Zig libraries play now. Library *logic* you want in the hot path is pulled in
  as Koru source; genuine external effects sit behind an FFI port. Never dynamic
  dispatch into a "sloppy JS module" from a hot loop.
- Koru-authored code has **no dynamic dispatch anywhere**, by construction.

## THE benchmark target — and the trap to avoid

**DO NOT benchmark Koru `for`/loops/arithmetic/folds against JS.** That is a
rigged loss: V8 optimizes a flat loop to ~0.46 ns/el, emitted JS can at best tie
it, and the only thing that ever beat it (closed-form loop fold) is LLVM-only and
does not survive to V8. Loop benchmarks tie or lose. Pointless.

**DO benchmark the event pump at chained dispatch depth** (vaxis-shaped). This is
the unlock: dynamic dispatch is how the overwhelming majority of real JS apps are
built (React events→reducers→effects, Node EventEmitters, DOM bubbling, RxJS
operator chains, middleware), and it is the one place JS is *structurally* worst
and Koru *structurally* wins.

Success criterion: emit a **vaxis-shaped event pump** to real `output_emitted.js`,
run it through the chained-dispatch benchmark, and confirm the static-dispatch
numbers below hold on genuine emitter output.

## Two senses of "fold" — keep them separate

1. **Dispatch collapse** (event pump → static direct calls, no dynamic dispatch):
   REAL, V8-survivable, the whole point. This is what transfers.
2. **Arithmetic fold** (loop → Gauss constant): LLVM-only. Does NOT transfer to
   V8. DROPPED. Never claim it for a JS target.

## Settled invariants (with receipts)

- **Koru does not fold; it emits foldable-*shaped* code.**
  Receipt: `tests/.../sum_range_foldable/koru/output_emitted.zig:41-42` still
  contains `for (0..n) |i| { acc = v(.{...}); }`. The loop is emitted verbatim.
- **The closed-form fold is LLVM's.** Koru→Zig wall time is flat ~23 ms across
  n=1e6…1e9 while the source loop is O(n). (benchmarks/results/sum_range_foldable.csv)
- **V8 does not do that fold.** Committed JS results are linear:
  120→464→3987→38189 ms for 10× steps of n. (same CSV)
- **Static dispatch is the transferable win.** Koru's event pump emits static
  direct calls: `400_081` emits `const Handlers_0 = struct { fn step(v){...} }`
  called directly via `comptime __H`; vaxis `run` switches on the external input
  event and calls `key(...)`/`resize(...)` directly — no listener registry, no
  vtable, no string-keyed dispatch.

## Measured numbers (HAND-MODELED JS — to be replaced by real emitter output)

Single dispatch layer (vaxis-shaped event mix, Node):
- EventEmitter (idiom):      11.84 ns/event
- koru static (modeled):      3.56 ns/event   → **3.3× structural, survives V8**

Dispatch chain, ns per hop, depth sweep:
```
          K=1    K=4    K=8    K=16
emitter   11.1   11.1   12.4   11.6   <- FLAT: dynamic dispatch never fuses (the floor)
static     3.3    4.4    4.1    4.7   <- ~3× guaranteed
fused      2.1    0.9    0.7    0.6   <- up to ~19× IF emitter inlines the static chain
```
- The flat emitter row is the structural proof: dynamic dispatch is a fixed
  per-hop cost V8 cannot optimize across.
- Fusing the static chain is **emit-time textual inlining** (the emitter knows
  stage1→stage2→stage3), NOT LLVM magic — so the upside is actually reachable on
  JS. Floor ~3×, ceiling ~19× gated on emitter sophistication.

Context (not the target): emitted JS ties hand-written flat loops (~1.0×) and
beats the lazy-generator streaming idiom ~20× — but neither is the headline.

## Architecture seam (scoped + verified)

**Emission = one central visitor.** `VisitorEmitter` (src/visitor_emitter.zig:250),
entry `emit()` at :569. It walks `source_file.items`, calls `visitItem()` per item,
and recurses. Input contract: `*const ast.Program` (analyzed AST, post all Stage C
passes). Output: a string built in a `CodeEmitter` buffer.

**`lang` field already exists** (:273, default `"zig"`) but TODAY it only gates which
`|<lang>` proc body gets spliced — it does NOT switch structural syntax.

**Structural Zig is hard-coded at the write sites** (verified, e.g. :669, :699-708:
`code_emitter.write("const __koru_std = @import(\"std\");\n")`, `write("pub fn
comptime_main(...")`). So a JS emitter is a **parallel `JsVisitorEmitter`** that
mirrors the AST walk and rewrites every output site. NOT a subclass/override — these
are inline writes, not virtual methods.
- REUSE (logic, language-agnostic): AST walk, event↔proc matching (:2200+), flow
  ordering, input-field binding extraction, tap/metatype scanning.
- REPLACE (output text): struct→object/closure, `union(enum)`→`{tag,...}`,
  `pub fn handler`→`function`, drop `_ = &x` discards, module wrapper, `main()`.

**Proc bodies** are opaque strings `proc.body: []const u8` (ast.zig), selected by
`proc.target` match at :2237, spliced at :2324. JS target splices `|js` bodies the
same way `|zig` bodies are spliced today.

**Filename + write** live in main.zig (hard-coded `"output_emitted.zig"` ~:2905,
write ~:2922) — branch on `config.lang` for the extension. **Emitter selection** is
driven from `koru_std/compiler.kz` `emit_zig|zig` proc (~:1326-1393) which constructs
the `VisitorEmitter` — that's where `lang=="js"` would pick `JsVisitorEmitter`.
(compiler.kz path is agent-reported; NOT yet verified by me — confirm before editing.)

**Verdict:** one clean visitor = good. But the minimal JS emitter is a real ~2–3 day
parallel-emitter build, not a trivial fork. Made tractable by stripping to the
event-pump subset (events, effect handlers, terminal branches, flows, main, |js
bodies) and skipping taps / modules / comptime / metatypes for the spike.

## Minimal build plan

- **A. Target program** — write `js_pump.kz`: a vaxis-shaped event pump (a `run`-style
  proc that fires `! tick`/`! key` effect branches in a loop) with `|js` proc bodies,
  composable to a configurable chain depth. This is what we emit + benchmark. Its side
  effects are synthetic (array/counter), NOT libvaxis FFI, so `node` can run it.
- **B. JsVisitorEmitter** — minimal parallel emitter for just the constructs A uses.
- **C. Wiring** — branch on `config.lang` for emitter selection (compiler.kz) +
  filename (main.zig) → `output_emitted.js`.
- **D. Validate** — emit, `node output_emitted.js`, then run the REAL emitted JS
  through the chained-dispatch benchmark vs the Node EventEmitter baseline. Replace
  the hand-modeled numbers above with real-emitter numbers.

## Non-goals

- Don't try to beat JS at loops/arithmetic.
- Don't integrate with the npm/JS module system except as an FFI port.
- Don't port the whole language — minimal subset to emit one event pump.
