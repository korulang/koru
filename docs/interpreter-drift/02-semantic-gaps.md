<!-- SemanticGaps scout, 2026-08-07, interpreter-drift party. -->

> **PROVENANCE — READ BEFORE TRUSTING A ROW.**
>
> Entirely source-derived. **No probe was executed.** The agent hit a sandbox
> where every write returned `Operation not permitted` — repo, home and `/tmp`
> alike — so it could neither create a `.kz` probe nor write this file. It
> traced the code paths by hand instead.
>
> Every claim is therefore **[INFERENCE]** unless it cites a pinned test whose
> output was recorded elsewhere (`430_041`, `430_025`, `430_056` were measured
> by the lead on 2026-08-07 and are real). The reasoning is specific and cites
> file:line throughout, which makes this a good map and a poor witness.
> Section 6 lists the probe matrix that would turn it into evidence.
>
> Do not pin a regression test from this document without running the probe.

# Interpreter semantic drift — what EXECUTES wrong or not at all

Investigated 2026-08-07 (SemanticGaps). Focus: semantics once parsing has succeeded.
Scope: the interpreter execution machinery in `koru_std/interpreter.kz` and the
generated dispatcher coercion in `koru_std/runtime.kz`. Probe execution was not
possible (write-blocked sandbox); every behavior below is a deterministic
trace of the exact coercion/evaluation functions, plus the recorded outputs of
the three pinned-red tests.

## 0. Architecture — TWO evaluators, one used for args

The interpreter has two separate expression evaluators, and which one runs
depends on context. This asymmetry is the root of most semantic gaps:

1. **`evaluateExpr` — STRING evaluator** (interpreter.kz:1631-1679). Given the
   raw arg text, it does ad-hoc string surgery: strip surrounding quotes
   (1634-1637), else if the text contains any `.` treat it as `binding.field`
   (1639-1661), else look up a whole-token binding (1663-1670), else return the
   token verbatim (1672-1675). **This is THE argument-coercion path**: every
   dispatched event's args pass through it (interpreter.kz:2183-2190,
   `evaluated_args[i].value = evaluateExpr(arg.value, env, allocator)`).
2. **`evaluateExpression` / `evaluateExprNode` — AST evaluator**
   (interpreter.kz:864-955). Real recursive evaluator: number/string/bool
   literals, binary ops (arith + comparisons, 917-937), unary, single-level
   field access (902-915), grouped. Used ONLY for `if`/`while` conditions
   (1716-1780), and branch-constructor return values (2388-2442).

Consequence (verified by code path): a decimal literal `3.5` or an expression
`a + b` behaves differently in a condition/return (works, via evaluator #2)
than in an event argument (breaks or is passed literally, via evaluator #1).

`run` parses with `flow_parser.parseFlow` (fast path), falls back to the full
`koru_parser.Parser` on failure, then `validateFlow` (shadowing check only),
then `executeFlow` (interpreter.kz:1141-1255). `executeFlow` (1690-2463) is
the per-node executor: it special-cases `if`/`for`/`while` (1706-2140), else
normal dispatch, then matches a continuation by branch name (2298+) and
recurses into the next node; if no continuation matches it returns
`error.NoBranchMatch` (interpreter.kz:2462).

## 1. SILENTLY WRONG — the dangerous ones (called out first)

Each row: what happens, what makes it silent (the swallow), evidence.

### S1. f64 LITERAL argument arrives as 0 — pinned red, 430_041
`set-config(enabled: true, ratio: 3.5, count: 42)`.
- `evaluateExpr("3.5")`: not a quoted string; contains `.` at index 1 → split
  into binding `"3"`, field `"5"` (interpreter.kz:1640-1642). `env.get("3")` is
  null → returns `<unbound:3>` (interpreter.kz:1660).
- Dispatcher `buildInput` for a `.float` field: `parseFloat(F, "<unbound:3>") catch 0`
  → **0.0** (runtime.kz:835-836).
- **Silent because**: `catch 0`. No error surface. 430_041's expected.txt
  asserts `ratio=3.5`; the code path makes that impossible. Integers are
  unaffected (no dot → returned verbatim → `parseInt catch 0` succeeds), which
  is why `count: 42` and `enabled: true` work and only the float is destroyed.
- Affects EVERY decimal literal in argument position: `2.5`, `-3.5`, `1e3`,
  `0.5`. Marked SILENTLY WRONG.

### S2. binding-field access in ARGUMENT position resolves to a literal — pinned red, 430_025
Flow `compute(...) | result r |> print-result(r.value)`.
- `evaluateExpr("r.value")` → binding `r`, field `value`. The dispatch result
  for a single-scalar return has the field NAMED `__type_ref` (runtime.kz
  codegen, ~893-905 stores value on `__type_ref`) — there is no field named
  `value`. `evaluateExpr` finds no `value` field → returns the placeholder
  `<r.value>` (interpreter.kz:1656-1658).
- `print-result` receives the literal text `<r.value>`.
- **Silent because**: the `<{binding}.{field}>` placeholder string (1656-1658) —
  it is a well-formed value that flows all the way to the user. Pinned at
  430_025; TODO text confirms it is "parked on binding-field access in ARGUMENT
  position".
- Deep reason: scalar results are surfaced as `__type_ref`, and the string
  evaluator matches fields by exact name, so the idiomatic `.value` accessor
  simply never resolves.

### S3. A `tor` argument of OPTIONAL / STRUCT / LIST(offset) / ENUM / non-u8-pointer type is silently zeroed
`buildInput` (runtime.kz:829-858) only understands `bool`, integer types,
floats, and `[]const u8`. Everything else falls into the final `else`:
`@field(input, field.name) = mem.zeroes(F)` (runtime.kz:849-853).
- `?T` optional → `@typeInfo` = `.optional` → `mem.zeroes(?T)` = `null` always.
  A passed optional value is dropped even when present. **SILENTLY WRONG**.
- struct/record → `.struct` → `mem.zeroes` = all-zero struct. **SILENTLY WRONG**.
- list/array of non-u8 (`[]const i64`, `[3]u8`, etc.) → `.pointer` with
  size != slice-of-u8 → `mem.zeroes` = empty slice / null. **SILENTLY WRONG**.
- enum → `.enum` → `mem.zeroes` = zero/first variant regardless of the passed
  token. **SILENTLY WRONG**.
- `*T` raw pointer (not `[]const u8`) → `mem.zeroes` = null. **SILENTLY WRONG** (see
  S6 for the string/`[]const u8` exception which works).
- These are silent because `mem.zeroes` is a default, not an error.

### S4. Expressions (`a + b`, `a > b`) in ARGUMENT position are passed verbatim, not evaluated
`evaluateExpr("a + b")` (interpreter.kz:1631) has no arithmetic/relation case:
no `.` (assuming bare identifiers) → `env.get("a + b")` null → returns the
string `"a + b"` verbatim (1672-1675).
- If the param is a string: receives the literal text `"a + b"`. **SILENTLY
  WRONG** (no evaluation; wrong value, no error).
- If the param is an int/float: `parseInt("a + b") catch 0` → 0. **SILENTLY
  WRONG**.
- NOTE: the SAME expression DOES evaluate correctly in an `if`/`while`
  condition (AST evaluator, interpreter.kz:917-937) and in a branch-constructor
  return value. So `| result { value: a + b }` works while
  `set-config(count: a + b)` silently mangles. This split is the core
  emergency: the language's most common composed value cannot be threaded
  through an event call.

### S5. NESTED field access (`r.user.name`) never resolves
- String evaluator: splits on the FIRST `.` → binding `r`, field `user.name`
  → no field named `user.name` in the bound Value's fields → placeholder
  `<r.user.name>` (interpreter.kz:1639-1658). **SILENTLY WRONG**.
- AST evaluator field access (902-915) is single-level only: builds lookup key
  `"obj.field"` into expr_bindings, and expr_bindings are only ever populated
  single-level (`binding.field`, interpreter.kz:2400-2410). Deep access has no
  key. **SILENTLY WRONG**. No evaluator supports nesting.

### S6. pointer/handle — string slices WORK, but only by raw text
- `[]const u8` param: `getArg` strips quotes then hands the raw string
  (runtime.kz:819-828, 843-846) — WORKS for string data.
- A resource handle is tracked by the handle_pool as a string id and checked
  by `assertHandlesHeld` on the arg.value (interpreter.kz:1437-1461,
  2202-2204). Passing a handle that the pool holds by its raw id WORKS; a
  handle id that must be DERIVED from a bound result field is subject to S2/S5
  (placeholder text fails the pool lookup → `error.HandleNotHeld` →
  dispatch-error — this one DOES surface, as an error, not silently).
- Non-slice `*T` pointer arg → `mem.zeroes` = null (S3). SILENTLY WRONG.

## 2. WORKS (no mutation) — verified by code path
- **string literal**: `"World"` → quote-strip (1634-1637) → clean. WORKS.
- **bool**: `true`/`false` → no dot → returned verbatim (1672) → buildInput
  compares `== "true"` (830-833). WORKS.
- **i64/u64 integer literal**: no dot → verbatim → `parseInt(F,...) catch 0`
  succeeds → correct. WORKS.
- **binding as whole token**: passing an entire already-bound name (e.g. a
  prior scalar result bound as `v`) → `env.get(v)` → returns branch/first-field
  (1663-1670). WORKS for a scalar `__type_ref` field (first field).
- **field reference with matching name**: `v.ratio` when `v` was bound with a
  real `ratio` field → exact-name lookup → `fieldValueToString` → "3.5" →
  parseFloat succeeds. WORKS. (Field floats round-trip; only LITERAL decimals
  break — S1.)
- **`if`/`while` conditions and branch-constructor returns**: AST evaluator
  handles literals, all comparisons, arithmetic, single-level field access, and
  bool logic correctly (interpreter.kz:864-955; 1716-1780; 2000-2040). Works.

## 3. The three NEEDS_RULING behaviors (430_056) — reproduced analytically

A flow `pick(n)` with branches `| ok i64` / `| bad string` behaves three ways
(measured 2026-08-07 per NEEDS_RULING; confirmed against code):
- **A — ZERO arms, `bad` fires** → `executeFlow` sees `continuations.len == 0`
  → returns the dispatch result directly with `branch="bad"` intact
  (interpreter.kz:2298-2304). Outcome LEAKS to the caller. WORKS-as-is.
- **B — only `| ok` handled, `bad` fires** → no continuation matches `"bad"` →
  `error.NoBranchMatch` (interpreter.kz:2462) → surfaces as `dispatch-error`.
  ERROR (a stubborn one: fewer arms is more permissive than some arms).
- **C — `| ok` handled, `ok` fires** → arm runs, but the chain ends in a VOID
  event (`note(...)`), and the generated dispatcher reports a void event with
  `branch = ""` (runtime.kz:900-908) → the run's result comes back with
  `branch=[]` — the name is LOST. This is a separate defect from the ruling:
  a terminal void event overwrites the flow's real branch with an empty one.
  Marked SILENTLY WRONG (host sees an empty branch, no error).

These three are the subject of the `NEEDS_RULING` at
430_056_partially_handled_interpreted_flow/ — I do not rule, I document.

## 4. Control flow + subflow semantics (conditional on the parser surfacing them)

[INFERENCE on syntax: whether flow_parser emits `if`/`for`/`while` as
invocations is SyntaxMatrix's chartership (drift/01). SEMANTICS below are
what `executeFlow` DOES with them once parsed.]

- **`if`** (1690-1800): condition evaluated via AST evaluator (correct for
  literals/bindings/single-level fields/comparisons/arith); branch set to
  `then`/`else`; then matched against `| then`/`| else` continuations.
  Semantic hazards: a scalar result bound as `v` populates `expr_bindings[v]`
  but NOT `expr_bindings[v.value]` (2344-2382), so `if(v.value)` fails to
  resolve → UnknownBinding → condition forced to `false` (1722-1728) — silently
  takes the ELSE arm. SILENTLY WRONG edge.
- **`for`** (1800-1900): range is read RAW from `inv.args[0].value` and split on
  `..` with `parseInt(...) catch 0` (1794-1798). A bound/integer binding in the
  range (e.g. `for(0..N)`) → `parseInt("N") catch 0` → **end=0 → loop body never
  runs**. SILENTLY WRONG. Literal `for(0..5)` works. Loop var bound per
  iteration; body runs via recursion; `| done` followed.
- **`while`** (1900-2140): condition parsed from `"cond in {state}"`, state
  parsed from braces with `parseInt catch 0` for values not in-braces
  (1927-1943); `| continue`/`| done`; hard cap 10000 iterations. Reasonably
  functional for int state; nested field access in conditions hits S5.
- **Subflow CALL**: there is no flow-to-flow call. Every invoked name is
  dispatched to a registered event `tor` via `ctx.dispatcher`
  (interpreter.kz:2206). A labeled/named multi-step flow, or a flow
  dereference/label, hits `error.UnsupportedNode` (interpreter.kz:2449
  `// TODO: Handle labels, derefs`). Calling another REGISTERED event tor works
  (that is the whole model) but a user-defined re-useable subflow of steps does
  not exist. FUNCTION CALLS in expressions return `ExprEvalError.InvalidExpression`
  (interpreter.kz:878).

## 5. Per-construct result table

| Construct (runtime dispatch)        | Status        | Swallow mechanism                    | Evidence |
|-------------------------------------|---------------|--------------------------------------|----------|
| string literal `"x"`               | works         | —                                    | 1634-37  |
| bool `true`/`false`                 | works         | —                                    | 1672,830 |
| i64 / u64 literal                   | works         | —                                    | 1672,833 |
| **f64 literal `3.5`**               | SILENTLY WRONG → 0 | `parseFloat catch 0`            | 1640-60, r.kz 836 |
| **optional `?T`**                   | SILENTLY WRONG → null | `mem.zeroes`                 | r.kz 849 |
| **struct / record**                 | SILENTLY WRONG → zeroed | `mem.zeroes`             | r.kz 849 |
| **list / array (non-u8)**           | SILENTLY WRONG → empty | `mem.zeroes`               | r.kz 849 |
| **enum**                            | SILENTLY WRONG → first variant | `mem.zeroes`        | r.kz 849 |
| `[]const u8` string* / handle-by-id | works          | —                                    | r.kz 843 |
| non-slice `*T` pointer              | SILENTLY WRONG → null | `mem.zeroes`             | r.kz 849 |
| **binding ref `v` (whole)**         | works          | —                                    | 1663-70  |
| **field ref `v.ratio` (exact match)**| works          | —                                    | 1643-51  |
| **field ref `r.value` (scalar)**    | SILENTLY WRONG → `<r.value>` | placeholder 1656-58 | 430_025 |
| **nested `r.user.name`**            | SILENTLY WRONG → `<...>` | placeholder/single-level | 1656-58,902-15 |
| **expression `a+b`/`a>b` (arg)**    | SILENTLY WRONG → literal/0 | verbatim 1672 + catch 0 | S4 |
| expression (condition/return)       | works          | AST evaluator                      | 917-42   |
| `if(v.value)` on scalar             | SILENTLY WRONG → else | UnknownBinding→false       | 1722-28,2344-82 |
| `for(0..N)` bound upper             | SILENTLY WRONG → 0 iters | `parseInt catch 0`        | 1794-98  |
| `while` int state                   | works          | —                                    | 1900+    |
| subflow / label call                | ERRORS (`UnsupportedNode`) | —                        | 2449     |
| no arms, branch fires               | works (leak)   | —                                    | 2298-04  |
| some arms, unhandled fires          | ERRORS (`NoBranchMatch`) | —                      | 2462     |
| arm fires, terminal void            | SILENTLY WRONG → branch `""` | void→`""` r.kz 900-08 | 430_056 C |

## 6. Recommended probe matrix (for the lead to pin once a write-capable
environment is available)

Write one `~std/runtime:register(scope:"t")` with typed `tor`s mirroring
430_041 (bool/f64/i64/u64 + one `?f64` optional + one struct + one `[]const
i64` list + one enum + one `[]const u8` handle param), then `koruc run` on a
source that calls each with a literal, and diff observed vs expected. The
biggest wins to pin first: S1 (f64→0), S4 (expr-in-arg), S2 (`.value`), S5
(nested), S3 (structured zeroing), and the `for(0..N)` bound. All six are
SILENTLY WRONG and none currently errors.

## 7. Bottom line

Six independent SILENT corruption paths hit runtime dispatch (S1-S6) — all
in the string `evaluateExpr` argument path and the `mem.zeroes` buildInput
fallback — and none of them errors, so an LLM/shell writing interpreted Koru
will silently burn floats, optionals, structs, lists, enums, expressions,
nested fields, and bound loop ranges. The AST evaluator (conditions/returns)
is sound; the split between it and the string argument path is the defect
to close. Three behaviors tie to the open NEEDS_RULING (leak vs strict vs
empty-branch); I document, do not rule.