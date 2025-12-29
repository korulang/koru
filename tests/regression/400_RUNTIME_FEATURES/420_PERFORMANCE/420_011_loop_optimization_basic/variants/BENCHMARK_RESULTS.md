# Loop Optimization Benchmark Results

**Date**: 2025-11-01
**Test**: Scientific comparison of optimization strategies
**Method**: Hand-optimized variants with hyperfine benchmarking

## Summary

We tested 4 variants to isolate the performance impact of different optimization strategies:

| Variant | Time (ms) | Speedup vs Baseline | Change |
|---------|-----------|---------------------|--------|
| v1_baseline | 8.6 ± 0.4 | 1.00x | Current emission (no optimizations) |
| v2_inline_keyword | 4.2 ± 0.3 | **2.05x** | Added `inline` keyword to handler |
| v4_manual_inline | 1.2 ± 0.1 | **7.17x** | Manually inlined handler body into loop |
| v5_native_for | 1.0 ± 0.2 | **8.51x** | Used native `for (0..N)` instead of while |

## Key Findings

### 1. `inline` Keyword: 2x Speedup ✅

**Impact**: 2.05x faster (8.6ms → 4.2ms)

Adding the `inline` keyword to the handler function gives a **significant 2x speedup** with essentially zero compiler complexity.

**Implementation**: One word change in code generation
```zig
// Before
pub fn handler(...) Output { }

// After
pub inline fn handler(...) Output { }
```

**What it eliminates:**
- Function call overhead
- (Partial) struct packing/unpacking optimization

**What remains:**
- Struct construction: `Input{ .i = ..., .limit = ..., .sum = ... }`
- Union construction: `Output{ .continue = {...} }`
- Union pattern matching: `result == .continue`

### 2. Manual Inlining: 7x Total Speedup (3.5x More) ✅

**Impact**: 7.17x faster vs baseline (8.6ms → 1.2ms)
**Incremental**: 3.5x faster vs inline keyword (4.2ms → 1.2ms)

Manually inlining the handler body eliminates ALL overhead:

**Before (with inline):**
```zig
var result = handler(.{ .i = i, .limit = limit, .sum = sum });
while (result == .@"continue") {
    const c = result.@"continue";
    main_loop_i = c.i + 1;
    main_loop_sum = c.sum;
    result = handler(.{ .i = i, .limit = limit, .sum = sum });
}
```

**After (manual inline):**
```zig
while (i < limit) {
    sum += i;
    i += 1;
}
```

**What it eliminates:**
- Struct construction (Input)
- Union construction (Output)
- Union pattern matching
- Variable unpacking
- ALL remaining abstraction overhead

### 3. For vs While: Negligible Difference (~20%)

**Impact**: 1.19x faster (1.2ms → 1.0ms)

Using native `for (0..N)` instead of `while` gives a small additional speedup, but it's within measurement noise.

**Conclusion**: Use whichever loop form is easier to emit from the compiler. The difference is minimal.

## Recommendations for Compiler Implementation

### Phase 1: Add `inline` Keyword (EASY WIN)

**Effort**: Trivial (one word in code generation)
**Gain**: 2x speedup
**Risk**: Zero

Modify the emitter to add `inline` to all event handler functions:
```zig
pub inline fn handler(__koru_event_input: Input) Output { }
```

This gives immediate 2x performance improvement with zero complexity.

### Phase 2: Full Handler Inlining (SIGNIFICANT WIN)

**Effort**: Moderate (AST transform)
**Gain**: Additional 3.5x speedup (7x total)
**Risk**: Low (well-understood transform)

Detect loop patterns and inline the handler body:

1. **Pattern detection:**
   - Label loop with recursive jump
   - Checker event (2 branches: continue/done)
   - Simple body (arithmetic/state updates)

2. **Transformation:**
   - Extract condition from handler: `if (i < limit)` → while condition
   - Extract body: `sum + i` → loop body
   - Replace handler call with inlined code

3. **Implementation approach:**
   - String substitution (no Zig parsing needed!)
   - Map variables: `__koru_event_input.i` → `loop_i`
   - Emit direct while loop

### Phase 3: Native For Loops (OPTIONAL)

**Effort**: Low (emit different loop form)
**Gain**: ~20% additional speedup
**Risk**: Low

If the loop is a simple counted loop (0..N), emit as `for (0..N)` instead of while.

This is a minor optimization and can be deferred.

## Performance Impact on Test Suite

**Test 2007 (this test):**
- Current: 8.6ms
- With inline: 4.2ms ✅ **Passes threshold**
- With full inline: 1.2ms ✅ **Far exceeds threshold**

**Expected impact on other tests:**
- Simple loops: 2x-7x speedup
- Complex numerical code (nbody): ~2-3x speedup
- Event-driven code becomes competitive with imperative

## Conclusion

The data is clear:

1. **Implement `inline` keyword immediately** - Trivial change, 2x speedup
2. **Implement full inlining next** - Moderate effort, 7x total speedup
3. **For vs while doesn't matter** - Emit whichever is simpler

This makes Koru loops genuinely fast. Without these optimizations, event-driven loops are impractical. With them, they're zero-cost abstractions.
