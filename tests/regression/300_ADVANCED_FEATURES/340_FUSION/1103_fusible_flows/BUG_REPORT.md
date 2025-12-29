# Bug Report: Inline Flow Continuation Chain Emission Error

## Status: OPEN
**Date Found:** 2025-10-10
**Found During:** Fusion optimization testing
**Severity:** High - Blocks pure Koru flow syntax with continuations

## Summary

When using pure Koru flow syntax with chained continuations and branch constructors, the code emitter generates malformed Zig code with duplicate switch branches and empty case bodies.

## Reproduction

### Input Code (test 1103)
```koru
~event add { x: i32, y: i32 } | done { result: i32 }
~proc add = done { result: x + y }

~event multiply { x: i32, factor: i32 } | done { result: i32 }
~proc multiply = done { result: x * factor }

~event calculate { a: i32, b: i32, c: i32 } | done { result: i32 }

// Pure Koru flow with chained continuations
~proc calculate = add(x: a, y: b)
| done sum |> multiply(x: sum.result, factor: c)
| done product |> done { result: product.result }
```

### Generated Code (BUGGY)
```zig
fn __inline_flow_1(args: add_event.Input) calculate_event.Output {
    const result = add_event.handler(args);
    return switch (result) {
        .done => ,                                       // ❌ EMPTY EXPRESSION!
        .done => .{ .done = .{ .result = auto } },      // ❌ DUPLICATE KEY!
    };
}
```

### Expected Code
```zig
fn __inline_flow_1(args: add_event.Input) calculate_event.Output {
    const result = add_event.handler(args);
    return switch (result) {
        .done => |sum| {
            const result_2 = multiply_event.handler(.{ .x = sum.result, .factor = c });
            return switch (result_2) {
                .done => |product| .{ .done = .{ .result = product.result } },
            };
        },
    };
}
```

## Error Message
```
Error: output_emitted.zig:113:22: error: expected expression or assignment, found ','
            .done => ,
                     ^
```

## Root Cause Analysis

### Location
- **File:** `/Users/larsde/src/koru/src/emitter.zig`
- **Function:** Inline flow emission (around lines 1320-1420)
- **Issue:** Continuation chain handling in switch generation

### Problem
The emitter correctly handles:
- Single continuations: `| done |> return_value`
- Simple pipelines: `| done |> ~next_event()`

But FAILS on:
- Chained continuations with variable bindings
- Multiple continuation steps in sequence
- Branch constructor syntax in continuation chains

### Technical Details

The switch generation code (line 1329+):
1. Iterates over `flow.continuations`
2. Groups by branch name
3. Generates switch cases

**Bug:** When continuations are chained:
- First continuation: `| done sum |>` (intermediate, should nest next call)
- Second continuation: `| done product |>` (final, should return)

The emitter treats them as separate switch branches instead of nested calls.

## Impact

**Blocks:**
- Pure Koru flow syntax with continuations
- Chained event calls in flows
- Branch constructor patterns
- **Fusion testing** (this was discovered while testing fusion)

**Workaround:**
Use Zig code in proc bodies instead of pure Koru flows:
```koru
~proc calculate {
    const sum = add_event.handler(.{ .x = a, .y = b });
    const product = multiply_event.handler(.{ .x = sum.done.result, .factor = c });
    return .{ .done = .{ .result = product.done.result } };
}
```

## Related Systems

### Shape Checking (Working Correctly)
- **File:** `src/shape_checker.zig`
- **Purpose:** Validates event branches match, shapes are compatible
- **Status:** ✅ Works - validates the AST correctly
- **Note:** Shape checking happens BEFORE code emission, so valid AST still fails at emission

### Union Collector (Working Correctly)
- **File:** `src/union_collector.zig`
- **Purpose:** Collects branch constructors from inline flows, builds union types
- **Status:** ✅ Works - correctly builds `SuperShape` from branch constructors
- **Note:** Creates proper AST structures, but emitter doesn't handle them correctly

### Code Emitter (BUGGY)
- **File:** `src/emitter.zig`
- **Function:** `emitFlow()` and switch generation (lines 1320-1600)
- **Status:** ❌ Broken for chained continuations
- **Issue:** Doesn't properly nest continuation calls

## Fix Strategy

### Option 1: Nest Continuation Calls (Recommended)
When encountering chained continuations:
1. First continuation opens a switch case with binding
2. Inside that case, emit the NEXT invocation
3. Recursively handle remaining continuations
4. Close nested switches properly

### Option 2: Transform to Sequential Code
Instead of nested switches, generate sequential Zig code:
```zig
const result_1 = first_event.handler(...);
const binding_1 = result_1.done;
const result_2 = second_event.handler(.{ .x = binding_1.field });
return .{ .done = .{ .result = result_2.done.field } };
```

### Option 3: Fix Pipeline Step Emission
The `emitContinuation()` function (line 3095) seems correct.
Issue might be in how inline flows invoke continuations vs regular flows.

## Testing

### Positive Test
- **Location:** `tests/regression/1100_FUSION/1103_fusible_flows/`
- **Purpose:** Tests pure Koru flow syntax with continuations
- **Status:** ❌ Failing due to this bug
- **Value:** Will verify fix works correctly

### Negative Test Needed
Once fixed, create:
- `tests/regression/9400_FUSION_ERRORS/9401_invalid_continuation_chain/`
- Test that malformed continuation chains are caught with helpful errors

## Architecture Notes

### Why This Matters for Fusion
Fusion optimization is designed to work on **pure Koru flows**:
```koru
~proc calculate = add(x: a, y: b) | done |> multiply(...) | done |> done {...}
```

This is the EXACT syntax that fusion targets:
- Pure events (marked `[pure]`)
- Chained through continuations
- Branch constructors for immediate returns

**Without this working, fusion cannot be properly tested!**

### The Compiler Pipeline

1. **Parser** → Creates AST with inline flows ✅
2. **Shape Checker** → Validates branches/types ✅
3. **Union Collector** → Builds SuperShape ✅
4. **Purity Analyzer** → Marks pure events ✅
5. **Fusion Detector** → Finds fusable chains ✅
6. **Fusion Optimizer** → Transforms AST ✅
7. **Code Emitter** → Generates Zig code ❌ **BROKEN HERE**

## Priority

**HIGH** - This blocks:
- Modern pure Koru syntax
- Fusion optimization testing
- Clean event composition patterns
- Future optimizations based on flow analysis

## Next Steps

1. Document shape checking architecture (DONE - this file)
2. Create negative test infrastructure
3. Fix emitter continuation chaining
4. Verify test 1103 passes
5. Continue with fusion development

## References

- Test: `tests/regression/1100_FUSION/1103_fusible_flows/`
- Emitter: `src/emitter.zig:1320-1600`
- Shape Checker: `src/shape_checker.zig`
- Union Collector: `src/union_collector.zig`
- Fusion Docs: `tests/regression/1100_FUSION/FUSION.md`
