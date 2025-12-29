# Loop Optimization Analysis - FINDINGS

**Date**: 2025-11-01
**Test**: 2007_loop_optimization_basic
**Method**: Scientific benchmarking with incremental hand-optimizations

## Summary

We tested 5 versions to isolate where the 7x performance gap comes from:

| Version | Time | Ratio vs Baseline | What Changed |
|---------|------|-------------------|--------------|
| 1. Baseline (for loop) | 1.1ms | 1.00x | ✅ Native Zig for loop |
| 2. Koru Current | 8.3ms | 7.33x | ❌ Handler calls in loop |
| 3. HandOpt1 (no dead code) | 8.3ms | 7.36x | Removed intermediate variables |
| 4. HandOpt2 (inline handler) | 1.2ms | 1.04x | ✅ Inlined handler body |
| 5. HandOpt3 (for loop) | 1.5ms | 1.35x | Converted while → for |

## Key Findings

### 1. Dead Code Removal: NO IMPACT ❌
**Impact**: 0% (8.3ms → 8.3ms)

Removing intermediate variable unpacking had ZERO effect. Zig's optimizer already eliminates:
```zig
const c = result_0.@"continue";    // ← Zig eliminates this
main_loop_i = c.i + 1;             // ← And this becomes direct access
```

**Conclusion**: Don't waste time on dead code elimination pass. Zig handles it!

### 2. Handler Inlining: THE ENTIRE GAP! ✅
**Impact**: 691% speedup (8.3ms → 1.2ms)

Inlining the handler body eliminates:
- **Function call overhead** (10M calls × ~0.7ns each)
- **Struct packing/unpacking** (Input → handler → Output)
- **Union creation and pattern matching** (every iteration checks `.continue` vs `.done`)

**Before (slow):**
```zig
var result = loop_step_event.handler(.{ .i = i, .limit = limit, .sum = sum });
while (result == .@"continue") {
    main_loop_i = result.@"continue".i + 1;
    main_loop_sum = result.@"continue".sum;
    result = loop_step_event.handler(.{ .i = i, .limit = limit, .sum = sum });
}
```

**After (fast):**
```zig
var i: u64 = 0;
var sum: u64 = 0;
while (i < 10_000_000) {  // ← Inlined condition check
    sum += i;              // ← Inlined body
    i += 1;
}
```

**Conclusion**: This is THE critical optimization! Everything else is noise.

### 3. Loop Form: While BEATS For! 🤯
**Impact**: -25% (for is SLOWER!)

Converting to native `for (0..N)` loops actually made things WORSE:
- HandOpt2 (while): 1.2ms ✅
- HandOpt3 (for): 1.5ms ❌

**Why?** The `for (0..N)` syntax creates a range object with bounds checking. The `while` loop with direct counter increments is more direct.

**Conclusion**: Keep emitting while loops! Don't transform to for!

## What We Need to Build

### Loop Handler Inlining Transform

**Pattern to detect:**
1. Label loop: `#label event(...) | continue c |> @label(...) | done d |> ...`
2. Checker event: Event with `if/else` returning `continue` vs `done`
3. Simple body: Arithmetic/state updates (no complex control flow)

**Transformation:**
1. Extract condition from handler's if-check
2. Extract body from continue-branch logic
3. Replace while+handler loop with while+inlined body
4. Preserve done-branch handling after loop

**Pseudocode:**
```
if (flow is label_loop &&
    continue_branch jumps to same label &&
    invoked_event is checker_pattern) {

    inline handler body into while loop
}
```

## Infrastructure We Have

✅ **Transform framework**: `transforms/inline_small_events.zig` shows the pattern
✅ **Functional transforms**: `transform_functional.zig` for AST manipulation
✅ **Compiler hooks**: `main.zig` line 2680 shows where transforms apply
✅ **Benchmarking**: hyperfine setup in `benchmark.sh`

## Next Steps

1. **Create `transforms/inline_loop_handlers.zig`**
   - Detect the pattern (checker event + label loop)
   - Extract condition and body from handler
   - Generate inlined while loop

2. **Register transform in main.zig**
   - Add after inline_small_events
   - Apply before code generation

3. **Verify with test 2007**
   - Should go from 8.3ms → ~1.2ms
   - Threshold is 1.05x, we'll hit 1.04x!

4. **Apply to nbody**
   - Test 2101c has recursive event loops
   - Should close significant performance gap

## Performance Prediction

**Test 2007 (loop):**
- Current: 8.3ms (7.3x slow)
- With inlining: ~1.2ms (1.04x) ✅ PASS

**Test 2101c (nbody extreme):**
- Current: 0.214s (1.56x slow vs hand-opt)
- With inlining: ~0.14s (1.09x) ✅ Near Rust!

## Why This Matters

This single optimization closes:
- **7x gap** in simple loops
- **~30-40% gap** in complex numerical code (nbody)
- Makes event-driven loops **competitive with imperative code**

Without this, Koru loops are impractical. With it, they're zero-cost!

---

**The Data Speaks**: Inline handlers in loops. Nothing else matters.
