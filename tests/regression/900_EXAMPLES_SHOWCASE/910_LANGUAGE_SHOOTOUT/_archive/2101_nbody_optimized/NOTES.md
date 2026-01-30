# 2101_nbody - N-Body Gravitational Simulation

## What This Tests

**Computational Characteristics:**
- Floating-point arithmetic (f64)
- Nested loops (O(n²) interactions)
- Mathematical operations (sqrt, multiplication, division)
- Array indexing and iteration
- State updates (positions and velocities)

**What We're Proving:**
- Event dispatch is zero-cost (compiles away)
- Multi-event flows compile to straight-line code
- Event composition equals direct function calls
- Koru's abstraction doesn't hurt numerical performance

## The Algorithm

**N-body simulation** models gravitational interactions between celestial bodies:

1. **Initialize** - Create 5 bodies (Sun, Jupiter, Saturn, Uranus, Neptune)
2. **Offset momentum** - Adjust sun's velocity so system momentum is zero
3. **Calculate energy** - Compute total kinetic + potential energy (baseline)
4. **Advance N times:**
   - Calculate gravitational forces between all pairs
   - Update velocities based on forces
   - Update positions based on velocities
5. **Calculate energy** - Final energy (should be close to initial, showing energy conservation)

## Event Decomposition

### ✅ HONEST Implementation (What We Did)

We decomposed the algorithm into focused, single-responsibility events:

```koru
// 8 focused events, each with clear responsibility:

1. initialize_bodies    - Create planetary system
2. offset_momentum      - Zero out system momentum
3. calculate_energy     - Compute total energy
4. calculate_interactions - Update velocities from forces
5. update_positions     - Update positions from velocities
6. print_energy         - Output energy value
7. simulation_step      - Loop counter logic
8. parse_args           - Parse command-line arguments

// Flow orchestrates these into the full algorithm
```

**What this proves:**
- Event abstraction compiles to same code as hand-written loops
- Flow composition has zero runtime cost
- Multiple small events = one monolithic function (after compilation)

### ❌ DISHONEST Approach (What We Avoided)

```koru
// This would be MEANINGLESS:
~event run_simulation { n: u32 } | done {}

~proc run_simulation {
    // 200 lines of Zig doing everything...
    // Just calling fast code, not testing event architecture
}
```

This would prove nothing about Koru's event system!

## Performance Expectations

### Threshold: 1.20x (Within 20% of hand-optimized Zig)

**Why this threshold?**
- Initial implementation, no hand-optimization
- Floating-point code is sensitive to code generation
- Want to be within striking distance of C/Zig

**Success looks like:**
```
C (gcc -O3):        0.041s  [gold standard]
Zig (ReleaseFast):  0.042s  [our target]
Koru → Zig:         0.048s  [event-driven]

Koru / Zig:  1.14x  ✅ Within threshold!
Zig / C:     1.02x  (baseline gap)
```

## Compiler Optimizations That Should Help

### Phase 1: Event Inlining
- All events should inline into main flow
- No actual function calls at runtime
- **Expected impact:** 10-15% improvement

### Phase 2: Loop Fusion
- `calculate_interactions` + `update_positions` → single loop
- Avoid intermediate array writes
- **Expected impact:** 5-8% improvement

### Phase 3: SIMD Vectorization
- Float operations can use SIMD
- Batch vector updates
- **Expected impact:** 20-30% improvement (when implemented)

## Running This Benchmark

**⚠️ NOTE: This benchmark is OPTIONAL (no MUST_RUN marker)**

Like `2004_rings_vs_channels`, this won't run automatically in CI. You must run it explicitly.

### Via Regression Suite
```bash
# Run just this benchmark
./run_regression.sh 2101

# Run all language shootout benchmarks
./run_regression.sh 21
```

### Manually
```bash
cd tests/regression/2100_LANGUAGE_SHOOTOUT/2101_nbody

# Compile and benchmark all versions
bash benchmark.sh

# Check threshold
bash post.sh
```

### What benchmark.sh Does
1. Compiles C reference (gcc -O3 -march=native)
2. Compiles Zig baseline (zig -O ReleaseFast)
3. Compiles Koru-generated code (zig -O ReleaseFast)
4. Verifies all produce correct output
5. Runs hyperfine with 3 warmup + 10 benchmark runs
6. Exports results.json

### What post.sh Does
1. Parses results.json
2. Calculates Koru/Zig ratio
3. Compares to THRESHOLD (1.20)
4. Reports pass/fail with context

## Correctness Verification

**Expected output for N=50000:**
```
-0.169075164
-0.169078071
```

These are:
- Initial energy after momentum offset
- Final energy after 50000 simulation steps

**Energy conservation check:**
- Values should be very close (differ by ~0.000003)
- Shows numerical stability of symplectic integrator
- Any significant difference indicates algorithmic error

## Reference Implementations

### C Reference
- Source: https://benchmarksgame-team.pages.debian.net/benchmarksgame/program/nbody-gcc-1.html
- License: Revised BSD
- File: `reference/reference.c`
- Purpose: Generate expected.txt, gold standard reference

### Zig Baseline
- Hand-optimized Zig port of C algorithm
- File: `reference/baseline.zig`
- Purpose: This is what Koru SHOULD compile to
- Clean, readable, equivalent algorithm to Koru

### Koru Implementation
- File: `input.kz`
- Event-driven with proper decomposition
- Should compile to code similar to baseline.zig

## Performance History

| Date | Commit | Koru/Zig Ratio | Change | Notes |
|------|--------|----------------|--------|-------|
| 2024-10-25 | (initial) | TBD | - | Initial implementation with event decomposition |

## Known Optimization Opportunities

1. **Event inlining** - Currently separate functions, should inline
2. **Loop fusion** - Separate velocity/position updates could fuse
3. **Constant propagation** - `dt = 0.01` is constant, can optimize
4. **Array bounds elimination** - Fixed size [5]Body, no runtime checks needed

## Success Criteria

**Correctness:**
- ✅ Output matches expected.txt exactly
- ✅ Energy conservation within tolerance

**Performance:**
- 🎯 Within 1.20x of Zig baseline (initial target)
- 🎯 Understand gap to C/Zig (inform optimization priorities)
- 🎯 Track improvements as compiler evolves

**Code Quality:**
- ✅ Proper event decomposition (no giant procs!)
- ✅ Demonstrates event composition benefits
- ✅ Readable, maintainable, honest implementation

## Related Benchmarks

- **2102_fannkuch_redux** - Array manipulation (tests different patterns)
- **2103_binary_trees** - Memory allocation (tests GC/allocator)
- **2104_mandelbrot** - Parallel potential (future concurrency test)

## References

- [Computer Language Benchmarks Game](https://benchmarksgame-team.pages.debian.net/benchmarksgame/)
- [N-body description](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/nbody.html)
- [Category README](../README.md)
- [Category SPEC](../SPEC.md)
