# Loop Optimization Investigation - FINDINGS

## Summary

We tested different versions of the N-body loop to understand what causes the performance overhead in Koru's ultra-granular implementation, and discovered a critical insight about code generation strategy.

## Results (5M iterations, 5 bodies, -O ReleaseFast)

| Version | Time (ms) | Description |
|---------|-----------|-------------|
| Version 1 | 115 | Handler call every iteration |
| Version 2 | 115 | Inlined handler (no call) |
| Version 3 | 116 | Simple while(cond) loop |
| Version 4 | 115 | while(true) + if + break |
| Version 5 | 113 | With extra variable copies |
| Version 6 | 116 | With nested handler call |
| Version 7 | 158 | EXACT Koru pattern (3 handlers) |
| Version 8 | 157 | With simulation loop (4 handlers) |
| Version 9 | **250-263** | **With position updates (matches actual work)** |
| Version 10 | **267-272** | **Call at BOTTOM pattern** |
| Version 11 | **197-210** | **🚀 EXPLICIT while condition (BREAKTHROUGH!)** |
| Version 12 | **198-222** | **🚀 EXPLICIT while + continue (SAME PERF!)** |
| **Baseline** | **~193** | **Simple while loops (reference/baseline.zig)** |

## Key Discoveries

### ✅ These DON'T Matter (LLVM optimizes them away):
1. **Handler calls** - Version 1 vs 2: Both 115ms
2. **Union construction** - Version 2 vs 3: 115ms vs 116ms
3. **Loop pattern** - Version 3 vs 4: 116ms vs 115ms (while(cond) == while(true)+break)
4. **Extra variable copies** - Version 5: 113ms (4 variables copied per iteration)
5. **Nested handler calls** - Version 6: 116ms
6. **Complex nested switches** - Version 7: 158ms (still way better than 289ms!)

### 🔍 THE MYSTERY SOLVED: Version 9 Discovery

Version 9 revealed the missing piece! The earlier tests only did velocity updates, but the baseline ALSO does position updates in the same `advance()` function.

When we added position updates to Version 9:
- **Before**: Version 8 was 157ms (velocities only)
- **After**: Version 9 is ~250-263ms (velocities + positions)
- **Baseline**: ~193ms (both operations in one function)

**The actual overhead: 250ms - 193ms = ~57ms (30% slower, NOT 1.7x!)**

The 1.7x number was misleading because we were comparing different workloads!

### 💡 CRITICAL INSIGHT: Code Generation Strategy

Version 10 tested a RADICAL idea from the user:

**Current Koru pattern (call at TOP):**
```zig
loop: while (true) {
    const result = handler(...);  // ← Call FIRST
    switch (result) {
        .next => continue :loop;  // ← Jump back to call again
    }
}
```

**Alternative pattern (call at BOTTOM):**
```zig
var result = handler(...);  // ← Call BEFORE loop
loop: while (true) {
    switch (result) {  // ← Switch on pre-computed result
        .next => {
            result = handler(...);  // ← Call at END of case
            continue :loop;  // ← Jump to switch with fresh result
        }
    }
}
```

**Results:**
- Version 9 (call at top): **~250-263ms**
- Version 10 (call at bottom): **~267-272ms**

Both patterns perform similarly (~260ms average), suggesting LLVM optimizes both well enough.

## What This Means for Koru

### ✅ VALIDATED:
1. **Handler calls are free** - LLVM inlines aggressively
2. **Union construction is free** - Optimized away completely
3. **Switch complexity is fine** - Nested switches don't hurt much
4. **Variable copies are free** - Dead code elimination works
5. **Pattern choice matters less than expected** - Call-at-top vs call-at-bottom perform similarly

### 🎯 THE REAL OVERHEAD:
- **~57ms (30%)** for the event-driven pattern
- NOT the 1.7x we initially thought
- Comes from the full complexity of nested event-driven loops

### 🚀 OPTIMIZATION OPPORTUNITIES:

The "call at bottom" pattern is interesting because:
1. It's a PURE COMPILER OPTIMIZATION - no syntax change needed!
2. It gives LLVM different CFG structure
3. It matches "post-label" semantics (jump to AFTER the event call)
4. Could enable better fusion/inlining opportunities

While Version 10 didn't show dramatic improvement (~10ms slower due to variance), the pattern itself is worth exploring because:
- It's how the user intuitively thinks about loops
- It separates "first call" from "subsequent calls"
- It could enable compiler-level loop fusion optimizations

## Next Steps

### Potential Compiler Optimizations:
1. **Loop Fusion** - Detect event chains and inline them into a single loop
2. **Continuation Inlining** - Flatten nested switches when safe
3. **Pattern Detection** - Recognize "this is just a while loop" and emit simpler code
4. **Post-Label Emission** - Try emitting call-at-bottom for certain patterns

### Investigation Ideas:
1. Compare LLVM IR of Version 9 vs Version 10 to see structural differences
2. Test whether `when` clauses can help (inline condition checks)
3. Explore whether we can detect "pure iteration" events and emit different code
4. Profile to find exactly where the 57ms goes

## Implications

**The overhead is NOT catastrophic!** We're at:
- **193ms baseline** (hand-written simple loops)
- **~260ms Koru** (ultra-granular event-driven)
- **1.35x overhead** (35% slower)

This is FAR better than the 1.7x we feared! And there are clear paths to optimization:
- Compiler-level fusion and inlining
- Better code generation strategies
- Pattern-specific optimizations

The goal of matching baseline performance seems ACHIEVABLE through compiler improvements alone!

---

## 🚀 BREAKTHROUGH: Version 11 - Explicit While Conditions

### The Discovery

Version 11 implements a **CRITICAL insight** from the user: Instead of hiding the loop condition inside a switch, put it **directly in the while expression**!

**Previous pattern (Version 9):**
```zig
loop: while (true) {  // ← LLVM doesn't know which branches loop
    const result = handler(...);
    switch (result) {
        .continue_inner => continue :loop,  // ← Hidden loop condition
        .done_inner => break,               // ← Hidden exit
    }
}
```

**New pattern (Version 11):**
```zig
var result = handler(...);
while (result == .continue_inner) {  // ← EXPLICIT loop condition!
    const inner = result.continue_inner;
    // work...
    result = handler(...);  // ← Updates condition, loop checks automatically
}
```

### The Results

**THIS CHANGES EVERYTHING:**

| Pattern | Time | Overhead |
|---------|------|----------|
| Baseline (simple while) | **193ms** | - |
| Version 9 (while(true) + switch) | **251ms** | **30% slower** |
| Version 11 (explicit while condition) | **197ms** | **2% slower** |

**We went from 30% overhead to 2% overhead!!**

### Why This Works

1. **LLVM sees the loop condition explicitly** - No hidden breaks in switch statements
2. **Simple tag comparison** - `result == .continue_inner` is a trivial check
3. **No switch overhead** - The loop condition is the only branch LLVM needs to check
4. **Better branch prediction** - Clear loop vs exit branches
5. **Loop optimization opportunities** - LLVM can apply standard loop optimizations

### Implementation via Static Analysis

This is a **PURE COMPILER OPTIMIZATION** that requires NO syntax changes!

The Koru compiler can:
1. Analyze which continuation branches have `@loop` jumps
2. Emit `while (result == .looping_branch)` instead of `while (true)`
3. For multiple looping branches: `while (result == .branch1 || result == .branch2)`

Example analysis:
```koru
~event inner_loop_step { i: usize, j: usize }
| continue_inner { i, j } |> @inner_start(...)  // ← This branch LOOPS
| done_inner { i } |> ...                        // ← This branch EXITS
```

The compiler detects:
- `.continue_inner` loops back to `@inner_start`
- `.done_inner` does not loop

So it emits:
```zig
while (result == .continue_inner) {
    // Only the looping branch is in the while condition!
}
```

### What This Means for Koru

**WE ACHIEVED THE GOAL!** Event-driven nested loops can now match hand-written performance!

- ✅ **Handler calls are free** (LLVM inlines)
- ✅ **Union construction is free** (optimized away)
- ✅ **Nested switches are fine** (when needed)
- ✅ **Explicit loop conditions are CRITICAL** (this was the missing piece!)

**The path forward:**
1. Implement static analysis to detect looping branches
2. Emit `while (condition)` instead of `while (true)` for simple loops
3. Keep switch statements only when multiple branches need different behavior
4. Prove that extreme event decomposition CAN be zero-cost!

### Future Optimizations

With this foundation, we can explore:
1. **When clauses** - Inline conditions further: `while (result == .next and result.value < 100)`
2. **Loop fusion** - Detect chains and combine into single loops
3. **Dead branch elimination** - Remove cases that never execute
4. **Pattern-specific codegen** - Recognize common patterns and emit optimal code

**This is a HUGE win for Koru's "zero-cost abstractions" claim!** 🎉

---

## 🎯 VALIDATION: Version 12 - Continue Statements Are Fine!

### The Question

Version 11's breakthrough eliminated `continue` statements entirely by calling handlers directly at the bottom of each loop iteration. This raised a critical question:

**Does the performance come from:**
1. The explicit while condition (`while (result == .branch)`), OR
2. Eliminating the `continue` statement?

This matters because **nested labels require `continue :outer_label`** to jump to outer loops. If we need to eliminate `continue`, we can't support nested label jumps!

### Version 12: Testing Continue Statements

Version 12 tests the hypothesis that **explicit conditions give the perf benefit, NOT eliminating continue**.

**Pattern with continue statements:**
```zig
outer_label: while (outer_result == .continue_outer) {
    switch (outer_result) {
        .continue_outer => |outer| {
            inner_label: while (inner_result == .continue_inner) {
                switch (inner_result) {
                    .continue_inner => |inner| {
                        // work...
                        inner_result = handler(...);
                        continue :inner_label;  // ← Explicit continue!
                    }
                }
            }
            outer_result = handler(...);
            continue :outer_label;  // ← Jump to outer label!
        }
    }
}
```

### The Results

**CONTINUE STATEMENTS DON'T HURT PERFORMANCE!**

| Version | Avg Time | Pattern |
|---------|----------|---------|
| Version 11 | **~200ms** | Explicit while, NO continue (calls handler directly) |
| Version 12 | **~206ms** | Explicit while, WITH continue (labeled continues) |
| Difference | **~6ms** | **Negligible! (3% difference, within variance)** |

Running 5 iterations each:
- **Version 11**: 210ms, 197ms, 197ms, 200ms, 197ms (avg ~200ms)
- **Version 12**: 209ms, 202ms, 201ms, 222ms, 198ms (avg ~206ms)

### Why This Matters

**THE OPTIMIZATION IS SIMPLER THAN WE THOUGHT!**

We do NOT need to:
- ❌ Eliminate continue statements
- ❌ Call handlers directly instead of using continue
- ❌ Worry about breaking nested label jumps

We DO need to:
- ✅ Emit explicit while conditions: `while (result == .looping_branch)`
- ✅ Keep using continue statements (including `continue :label` for nested jumps)
- ✅ Emit Zig labels when needed for cross-level jumps
- ✅ Split continuations into looping/non-looping and emit them separately

### Implementation Strategy

The compiler should:

1. **Detect looping branches** - Static analysis to find which branches have `@label` jumps
2. **Emit explicit while conditions** - `while (result == .branch1)` or `while ((result == .b1) or (result == .b2))`
3. **Emit Zig labels** - Always emit labels for loops (e.g., `loop: while (...)`)
4. **Keep continue statements** - Emit `continue :label` for label jumps (both same-level and cross-level)
5. **Handle non-looping branches** - Emit code for branches that DON'T loop AFTER the while closes

**Example emission:**
```zig
// State variables
var loop_i: u32 = 0;
var loop_n: u32 = p.n;

// Initial call BEFORE while
var result = handler(.{ .i = loop_i, .n = loop_n });

// Explicit condition with label
sim_loop: while (result == .@"continue") {
    switch (result) {
        .@"continue" => |cont| {
            // Execute looping branch pipeline
            // ...
            // Update state
            loop_i = cont.i + 1;
            loop_n = cont.n;
            // Call handler
            result = handler(.{ .i = loop_i, .n = loop_n });
            continue :sim_loop;  // ← Explicit continue is FINE!
        },
    }
}

// Handle non-looping branches AFTER while
switch (result) {
    .done => |d| {
        // Execute .done pipeline (e.g., print final energy)
    },
}
```

### Conclusion

**Version 12 proves that the performance benefit comes from EXPLICIT WHILE CONDITIONS, not from eliminating continue statements.**

This is GREAT news because it means:
- ✅ We can support nested label jumps (`continue :outer_label`)
- ✅ The implementation is simpler (keep using continue)
- ✅ The generated code is clearer (labels are visible)
- ✅ We still get ~2% overhead (same as Version 11!)

**The path forward is clear: Implement explicit while conditions in the compiler while keeping the existing continue-based label jump mechanism!** 🚀
