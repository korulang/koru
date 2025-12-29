# Nested Labels in Subflow Continuations - Codegen Bug Reproduction

**Status**: KNOWN BUG - Backend code generation issue

## Issue Description

Labels defined within **subflow continuation branches** (not at top-level flow) trigger a code generation bug in the Zig emitter. The emitter generates incomplete switch cases, resulting in invalid Zig syntax.

## Symptoms

- Frontend compilation succeeds
- Backend Zig code generation produces invalid Zig syntax
- Error: `expected expression or assignment, found ','`
- Pattern in generated code: `.continue_outer => ,` (missing expression after `=>`)

## Minimal Reproduction

This test demonstrates:
1. Outer loop with `continue_outer`/`done_outer` branches
2. Inner loop with `continue_inner`/`done_inner` branches
3. Label definition: `#inner_start`
4. Label reference: `@inner_start`
5. Nested branch handling from recursive call to `outer_step`
6. The problematic line: `| continue_outer co2 |> @inner_start(i: co2.i, j: 0)`

## Expected Behavior

Should generate valid Zig code that implements the nested recursive loop structure.

## Actual Behavior

Generates invalid Zig on line 100 of output_emitted.zig:
```zig
return switch (result) {
    .continue_outer => ,          // BUG: Missing expression!
    .done_outer => |done_o| .{ .done = .{ .result = done_o.i } },
};
```

## Root Cause

The Zig emitter (VisitorEmitter) can successfully handle labels defined at the **top-level of flows** (see test 205_nested_labels), but **fails when labels are defined inside subflow continuation branches**.

**Test 205 (WORKING):**
```koru
~start()
| ready |> #outer_loop outer(x: 1, max_inner: 2)  // Label at flow start
    | next_outer o |> #inner_loop inner(...)      // Nested label
        | next_inner i |> @inner_loop(...)         // Jump works
        | done_inner d |> @outer_loop(...)         // Jump works
    | done_outer |> _
```
Generates proper `while (true)` loops with Zig labeled `continue :label` statements.

**Test 320 (BROKEN - this test):**
```koru
~nested_loop = outer_step(i: start)                // Subflow definition
| continue_outer outer |> #inner_start inner_step(...)  // Label in CONTINUATION BRANCH
    ...
    | done_inner done_i |> outer_loop_step(...)
        | continue_outer co2 |> @inner_start(...)  // Jump from nested branch
```

The difference:
1. **Test 205**: Label defined at **top-level** flow invocation → emitter generates loops correctly
2. **Test 320**: Label defined in **continuation branch** of subflow → emitter fails

The emitter generates the switch case `.continue_outer =>` but **fails to emit the loop structure**, resulting in: `.continue_outer => ,`

## What Should Happen

The emitter should recognize that when a label is defined in a continuation branch, it needs to generate a `while (true)` loop structure similar to test 205:

```zig
// What test 205 generates (CORRECT):
var outer_loop_x: i32 = 1;
outer_loop: while (true) {
    const result = outer_event.handler(.{ .x = outer_loop_x, ... });
    switch (result) {
        .next_outer => |o| {
            // ... inner loop with continue :outer_loop
        },
        .done_outer => |_| {},
    }
    break;
}
```

Not this (BROKEN):
```zig
// What test 320 generates (BROKEN):
const result = outer_step_event.handler(.{ .i = start });
return switch (result) {
    .continue_outer => ,  // ← Missing loop structure!
    .done_outer => |done_o| .{ .done = .{ .result = done_o.i } },
};
```

## Important: Labels Are NOT Recursion

Labels compile to **iterative loops**, not recursive function calls:
- ✅ Uses `while (true)` with labeled `continue :label`
- ✅ Zero stack frames - pure iteration
- ✅ No TCO needed - not recursive
- ❌ NOT function recursion

The term "recursive" in comments was misleading. This is about **iterative loop control flow** with labels.

## Fix Complexity Assessment

### Current Architecture

The emitter has TWO separate code paths:

1. **Top-level flows** (`emitter_helpers.zig::emitFlow()` lines 1170-1310)
   - Handles labels via `flow.pre_label`
   - Generates `while (true)` loops with `continue :label`
   - Works perfectly (test 205 proves this)

2. **Subflow continuations** (`emitter_helpers.zig::emitSubflowContinuations()` lines 771-920)
   - Generates switch statements: `return switch (result) { ... }`
   - **Does NOT handle labels at all**
   - Assumes all branches terminate with `return .{ .branch = ... }`

### The Problem

Test 320 uses a **subflow** (not top-level flow):
```koru
~nested_loop = outer_step(i: start)  // ← Subflow, not flow
| continue_outer outer |> #inner_start inner_step(...)
```

`emitSubflowContinuations()` generates:
```zig
return switch (result) {
    .continue_outer => ,  // ← MISSING: should start a while loop
    .done_outer => |done_o| .{ .done = .{ .result = done_o.i } },
};
```

But it **needs** to generate (like test 205):
```zig
var outer_loop_x: i32 = 1;
outer_loop: while (true) {
    const result = outer_event.handler(...);
    switch (result) {
        .continue_outer => { /* nested logic */ },
        .done_outer => |_| {},
    }
    break;
}
```

### Fix Options

#### Option 1: Detect Labels in Subflows (MODERATE COMPLEXITY)

**Approach**: Modify `emitSubflowContinuations()` to detect when a continuation has a label definition, then switch from switch-based emission to loop-based emission.

**Changes needed**:
1. In `emitSubflowContinuationsWithDepth()` (line 781), check if any continuation in the pipeline has `.label_with_invocation`
2. If found, emit loop variables + `while (true)` wrapper (similar to `emitFlow()` lines 1197-1244)
3. Change from `return switch` to regular `switch` inside the loop
4. Handle `label_jump` cases to emit `continue :label` instead of return statements

**Complexity**: ~100-150 lines of new code, reusing existing logic from `emitFlow()`

**Risk**: LOW - mostly code reuse from working path

#### Option 2: Transform Subflows to Top-Level Flows (LARGE REFACTOR)

**Approach**: During AST processing, lift subflows with labels into top-level flows.

**Complexity**: HIGH - requires AST transformation pass

**Risk**: MEDIUM - changes compilation pipeline

#### Option 3: Unify Emitters (LARGE REFACTOR)

**Approach**: Merge `emitFlow()` and `emitSubflowContinuations()` into a single unified emitter.

**Complexity**: VERY HIGH - major architectural change

**Risk**: HIGH - could break many tests

### Recommendation

**Option 1** is the clear winner:
- ✅ Localized change (one function)
- ✅ Reuses proven loop emission logic from `emitFlow()`
- ✅ Low risk - doesn't touch working code paths
- ✅ Estimated effort: 2-4 hours for experienced Zig developer

The fix is **NOT too much work** - it's a straightforward extension of existing functionality.

## Related

- Found while implementing test 2101c_nbody_extreme
- Ultra-granular event decomposition of N-body simulation
- Nested loop iteration expressed as events (NOT recursion - iterative loops)
