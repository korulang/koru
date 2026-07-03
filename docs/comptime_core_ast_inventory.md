# Comptime Core-AST Inventory — the selective lower-to-AST survey

> **STATUS: INVENTORY + PROPOSAL.** The survey sections are grounded (file:line
> cited, verified 2026-07-03). The "proposed core set" and "fork" sections are
> design proposals — not ruled, not built. Companion to
> `docs/comptime_interpreter_vision.md` (the why); this is the what-exists and
> the what's-missing.
>
> Design center (Lars, 2026-07-03): the comptime interpreter is optimized for
> **completeness and correctness**, never at the cost of runtime performance.
> The lower-to-AST step is **selective**: comptime contexts get interpretable
> structured nodes; runtime contexts keep today's straight-to-host lowering
> untouched. The fork is by *stage*, not by construct — anything that survives
> to emission takes the fast path by definition.

---

## 1. The three lowering mechanisms that exist today

1. **`run_pass` transforms — already a fixpoint engine.**
   `transform_pass_runner.zig:599` `walkAndTransform` iterates
   walk→transform→restart **until a full walk finds zero transforms**
   (`MAX_ITERATIONS = 1000` circuit breaker). Registration is type-driven:
   an event with `*const Invocation`/`*const Item`/`*const EventDecl` input
   + `[comptime]` is a transform (`main.zig:1482-1515`); `~[transform]proc`
   is the qualified-dispatch variant (`emitter_helpers.zig:16-37`).
   **The multi-level machinery the Lisp model needs already exists here** —
   transform output re-enters the walk. What's missing is an *evaluator*
   participating in it.

2. **Keyword templates — the straight-to-host fast path.**
   `if`/`for` (`koru_std/control.kz:31,78`), `const`
   (`declarations.kz:41`), `table:from/sum/gaps` (`table.kz:24-60`) are
   `~proc NAME|template|zig` / `|js` Liquid procs. Rendered by
   `process-template-procs` **in the frontend stage** (`compiler.kz:761-786`)
   — upstream of analysis/optimize/emission. Output is literal host text in
   `inline_body`/`preamble_code`. Explicit doctrine in-source: *"`~if` is a
   `|template|zig` proc, NOT a dedicated AST node"* (`control.kz:22`). This
   is the performance path and it stays.

3. **Plain `[comptime]` flows — compiled execution.** Emitted as
   `comptime_flowN(program, allocator)` and executed by `comptime_main()` at
   Stage C Phase 2.5 (`compiler.kz:1683-1694`, `visitor_emitter.zig:1123-1137`).
   This is *execution*, but only of flows that compile down without
   transforms nesting inside them — the KORU010 wall the interpreter exists
   to remove.

## 2. Output-shape census (what transforms actually produce)

| Shape | Constructs |
|---|---|
| **Pure AST→AST** (interpretable) | `tap` only (`taps.kz:395,434` — inserts `.invocation` nodes) |
| **Mixed** | `capture` — structured `.assignment` nodes (`control.kz:238-241`) + a **Zig-text preamble** for the cell decl (`control.kz:345-370`) |
| **Host text** (`inline_body`/`.inline_code`) | print/eprint/fmt families, `types:struct/...`, `field:new*`, `list:new`, `kernel:*`, `regex:match/scan`, `switch:char`, `trellis:*`, `runtime:register`, `liquid_template:emit`, testing |
| **New declarations** | `parser_generator:parser` (derive: appends `.event_decl`/`.proc_decl`) |
| **Host text via template** (not run_pass) | `if`, `for`, `const`, `table:from/sum/gaps` |

Takeaway: **today's de-facto lowering target is host text.** Exactly one
transform is fully interpretable. The core-AST tier has almost no producers.

## 3. The half-built core vocabulary

The AST already declares the interpretable tier — with consumers built and
producers missing:

| Node | Declared | Producer | Emitter support | Printer |
|---|---|---|---|---|
| `assignment` | `ast.zig:1209` | ✅ capture (`control.kz:238`) | ✅ `emitter_helpers.zig:1804,8790` | ❌ |
| `foreach` | `ast.zig:1183` | ✅ kernel pairwise (`kernel.kz:1242`) | ✅ `:8533,9070` | ❌ |
| `conditional` | `ast.zig:1192` | ❌ **none** (verified) | ✅ `:8651,9114` | ❌ |
| `switch_result` | `ast.zig:1202` | ❌ **none** (verified) | ✅ `:8724` | ❌ |
| `native_loop` (IR item) | `ast.zig:316` | ❌ none (`optimizations/loops.kz` is a documented no-op) | ✅ Zig `for` emission `visitor_emitter.zig:1349-1449` | ❌ |
| `label_jump`/`label_apply`/`label_with_invocation` (`#loop`/`@loop`) | `ast.zig:1132-1141` | ✅ parser | ✅ `emitter_helpers.zig:8371-8500` | ✅ (jump-form gap: `label_with_invocation` jump unprintable) |
| `invocation`, `branch_constructor`, `expression`, `Continuation` dispatch | parser-level | ✅ parser | ✅ | ✅ |
| `ExprNode` tree (10 variants: literal, identifier, binary, unary, field_access, grouped, builtin_call, array_index, conditional, function_call) | `ast.zig:16-26` | ✅ `ExpressionParser`, attached opportunistically | n/a (emitter echoes raw text) | text-fidelity (never printed from tree) |

## 4. Proposed core-form set (the interpreter kernel) — PROPOSAL

The kernel interprets exactly:

1. `invocation` — event call, args evaluated, dispatch to flow/branch arms.
2. `Continuation` dispatch — branch arms, bindings, conditions
   (`condition_expr`), catchalls.
3. `assignment` — cell/field writes (incl. array index).
4. `foreach` — structured iteration (range or array), `each`/`done` arms.
5. `conditional` — structured if/else, `then`/`else` arms.
6. `label_with_invocation`/`label_jump`/`label_apply` — `#loop`/`@loop`
   guarded labeled recursion.
7. `branch_constructor` / `expression` — produce/construct results.
8. `switch_result` — later rung (no pin needs it yet).
9. Expressions — an evaluator over the `ExprNode` tree via
   `ExpressionParser`; numeric `builtin_call`s (`as`, `intCast`, …) get
   interpreter-native semantics.

Value model: ints, floats, bools, strings, arrays, cells/structs, **and AST
fragments** (`Source`) — the fragment variant is what makes multi-level
construction (the Lisp closure property) possible. Interpreter output is only
ever a value (spliced as literal) or Koru AST (spliced as program, re-enters
the fixpoint walk). **Never host text.**

## 5. The selective fork — PROPOSAL

Per-construct, at lowering time:

- **Runtime context (default): unchanged.** Templates render host text in
  frontend; emitter fast paths (incl. tail-dispatch flattening,
  `emitter_helpers.zig:9775-10154`) untouched.
- **Comptime context** (the construct is inside a flow being
  comptime-evaluated): the template is NOT rendered; the construct lowers to
  its structured core node (`for`→`foreach`, `if`→`conditional`) which the
  interpreter walks. These nodes never reach emission — the evaluator
  consumes them and splices results.
- `capture` in comptime context: same `.assignment` rewriting, but the
  Zig-text preamble is replaced by a structured cell-init the interpreter
  seeds directly from the capture invocation's args.

## 6. How far rung one gets

**310_090 (comptime capture-fold → 45)** needs: structured cell init,
`for`→`foreach` comptime lowering, `assignment` evaluation, ExprNode
evaluation (`+`, `as`/`intCast`), branch dispatch (`| captured r => result
r.s`), and value splicing into the runtime flow. All bounded; every consumer
data structure already exists.

**310_091 (comptime `#loop`)** needs: labeled-recursion interpretation
(6 above) plus the **call bridge** (§6a). Its `~proc |zig` bodies (`tick`,
`report`) are source-time procs — compiled into the running backend and
therefore host-callable by the interpreter. The pin stands as written.

### 6a. The thunk law + call bridge (RULED, Lars 2026-07-03; reframed same day)

The comptime capability boundary is **knowable-at-emission vs
born-at-comptime** — NOT purity, and not Koru-vs-Zig. The compiler already
does IO at comptime (the metacircular pipeline is IO); nothing is excluded
by kind:

- **Callable at comptime = thunked into the backend at Stage A.** For each
  event in the thunk policy, Stage A emits a wrapper into
  `backend_output_emitted.zig` marshalling interpreter Values ↔ the compiled
  handler's Input/Output structs. Stage B compiles it all natively; Stage C's
  interpreter calls through the table — no dynamic linking, no comptime
  codegen ever (the Jai comparison: Jai interprets everything in a bytecode
  VM inside the compiler; our Stage B pre-compiles the native half for free).
- **Thunk policy (recommended, not yet ruled): maximal by default** — thunk
  every source-time event with a proc handler. Completeness-first; cost is
  backend size/Stage-B time, bounded and measurable; narrow later if it
  hurts. File IO, print, arbitrary Zig procs: all comptime-callable — the
  cost of arbitrary Zig is writing Zig.
- **Generated code may call anything IN the table** — a fragment three
  levels deep invoking `std/io:*` is fine; the thunk exists. **The one hard
  wall: calls to procs born during comptime evaluation.** We cannot pretend
  to know what calls will be generated; a comptime-born proc has no compiler
  in the loop and cannot enter the table — it is runtime output only
  (precedent: `parser_generator:parser` synthesizes decls as Stage-D output,
  target-locked, level-zero).
- **Transform handlers are thunkable too:** they take `invocation`/`program`
  args, and the interpreter holds the actual invocation node when walking a
  call — it can pass the AST itself. (This is the baseline `missing struct
  field: invocation` Stage-B error from 310_098, solved in the right
  direction.) Own experiment when the bridge rung lands.

## 7. Open design questions (for Lars)

1. **Printability of core nodes.** `foreach`/`conditional`/`assignment` are
   transform-tier, unprintable by printer doctrine (`ast_printer.zig:19-21`).
   If we hold "every primitive has surface syntax," the printer grows
   spellings for them (and the roundtrip harness becomes a tripwire over the
   lowering). Alternative: core tier stays printer-exempt. (Recommendation:
   grow the spellings — the medium bed wants the lowered program printable.)
2. **Where the evaluator registers** — as a participant in the existing
   `run_pass` fixpoint walk (multi-level for free) vs a sibling loop around
   it. (Recommendation: in the walk.)

## Anchors

- Vision/why: `docs/comptime_interpreter_vision.md`. Pins: `310_090`,
  `310_091` (+ future pins per kernel form).
- Fixpoint walker: `src/transform_pass_runner.zig:599`.
- Fork point: `process-template-procs` (`koru_std/compiler.kz:761-786`),
  `src/template_processor.zig`.
- Kernel consumers already built: `emitter_helpers.zig` (§3 table).
- Do NOT touch: emitter fast paths (`emitter_helpers.zig:9775+`), the
  runtime template path, `src/interpreter.zig` (stays parked).
