# Task 004: Interpreter Decoupling from Generated Shapes

## Context
- Interpreter currently stringly-typed internally but still depends on generated per-event Input/Output structs via `~std.runtime:register` dispatcher.
- Goal: allow interpreter to run with scopes/sandboxing without needing those per-event shapes at runtime; keep performance competitive with existing 430_* benchmarks.
- Scope continues to be the unit of sandboxing; only registered events should be callable.

## Runtime Data Shapes (stable)
- `DispatchResult { branch: []const u8, fields: []NamedField(FieldValue) }`
- `FieldValue = union(string|int|float|bool)`
- `Value` mirrors `DispatchResult`; `Environment` maps binding -> Value
- `ExprBindings/ExprValue` for expression truthiness and field access
- No per-event generated structs required for interpreter runtime path.

## Dispatcher Rewrite (runtime.kz)
- Emit a `ScopeDescriptor` at comptime: scope name, event list, arg names per event, handler fn ptr.
- Generate `dispatch_<scope>` that:
  - Looks up event in descriptor; denies if not present.
  - Maps `[]Arg` to handler inputs by name without constructing `Input` structs.
  - Calls handler, extracts fields (string/int/float/bool) into `DispatchResult` using comptime reflection once.
- Keep signature `fn(*const Invocation, *DispatchResult) anyerror!void` to remain drop-in for interpreter.
- Enforce sandbox: only descriptor-listed events dispatch; others return `EventDenied` (align with interpreter).

## Interpreter Adjustments (interpreter.kz)
- Use descriptor-backed dispatcher; treat `DispatchResult` fields as already-typed `FieldValue`.
- Expression handling:
  - Reuse captured expression AST when available; avoid re-parsing strings.
  - Keep string fallback for literals/identifiers; preserve truthiness rules.
- Env/bindings:
  - Populate `expr_bindings` from `FieldValue` directly (no string parse where possible).
  - Minimize string dupes; keep arena reuse per run.
- Control flow:
  - Keep `~if`/`~for` special-cases; ensure branch selection uses AST path when present.
  - Maintain branch constructor behavior for continuations.
- Error semantics: normalize on `EventDenied` for disallowed events; keep `EventNotFound` only for missing-in-descriptor? (decision: prefer `Denied` for unregistered event names).

## Tests/Regression Targets (no full suite)
- Adjust/add 430_* to cover:
  - Dispatch without per-event `Input` structs (scope descriptor path).
  - Binding arg resolution still works (430_035).
  - Event denial vs not-found expectation (430_019).
  - `~if` using parsed expression AST (captures) without reparse.
  - Scope sandboxing: only registered events callable.
  - Performance sanity via existing benchmarks (430_014/025/030/036) spot-check only.

## Work Plan (steps)
1) Implement `ScopeDescriptor` + generic dispatcher generation in `runtime.kz`; align error semantics.
2) Update interpreter dispatch path to rely on descriptor-generated dispatcher; tighten bindings/expr population and AST reuse.
3) Refresh targeted 430_* regressions as above.
4) Light perf sanity (bench scripts) if time; no full regression run (user gate).

