# Computer Language Benchmarks Game - Koru Implementation

> **"Be within 20% of C/Zig, then optimize to beat them."**

This category implements classic benchmarks from the [Computer Language Benchmarks Game](https://benchmarksgame-team.pages.debian.net/benchmarksgame/) to:
- 🎯 Validate Koru's performance against established languages
- 📊 Track compiler optimization improvements over time
- 🚀 Provide real-world performance targets
- 🏆 Prove Koru can compete with C, Rust, and Zig

---

## Philosophy

These are **micro-benchmarks** - not realistic applications, but standardized tests that:
- Measure computational performance across languages
- Test specific characteristics (numeric, string, memory, I/O)
- Provide apples-to-apples comparisons
- Give clear optimization targets

### ⚠️ CRITICAL: Benchmark Integrity

**We test Koru's EVENT-DRIVEN ARCHITECTURE, not "can we call fast Zig code".**

**WRONG (Dishonest):**
```koru
~event run_benchmark { n: u32 } | done {}
~proc run_benchmark { /* 500 lines of Zig... */ }
```

**RIGHT (Honest):**
```koru
~event advance_bodies { bodies: []Body, dt: f64 } | advanced { bodies: []Body }
~event calculate_energy { bodies: []Body } | result { energy: f64 }
~event offset_momentum { bodies: []Body } | adjusted { bodies: []Body }

// Small, focused procs for each event
// Flow composition shows zero-cost abstraction
```

**What We're Proving:**
- ✅ Event dispatch is zero-cost (compiles away)
- ✅ Event composition equals direct function calls
- ✅ Koru's abstraction doesn't hurt performance
- ✅ Multi-event flows compile to straight-line code

**What We're NOT Proving:**
- ❌ "Koru can wrap fast Zig code" (meaningless)
- ❌ "We can avoid using Koru features" (dishonest)

### Success Criteria

**Success is NOT** about winning every benchmark.
**Success IS** about:
1. Being **competitive** (within 20% of hand-optimized C/Zig)
2. Being **honest** (proper event decomposition, not giant procs)
3. Knowing **where we stand** (honest measurements, all languages compared)
4. **Improving over time** (track trends across commits)
5. **Guiding optimization work** (what passes help which benchmarks)

---

## Test Structure

Each benchmark follows the `2000_PERFORMANCE` pattern:

```
210X_benchmark_name/
├── input.kz              # Koru implementation
├── reference/
│   ├── baseline.zig      # Hand-optimized Zig (primary comparison)
│   ├── reference.c       # C version (for reference)
│   └── reference.rs      # Rust version (optional)
├── MUST_RUN              # Must execute (not just compile)
├── THRESHOLD             # Max allowed ratio (e.g., 1.15 = 15% slower OK)
├── benchmark.sh          # Run both with hyperfine
├── post.sh               # Validate performance < threshold
├── expected.txt          # Correct output (verify correctness FIRST)
└── README.md             # What this benchmark tests
```

### Key Files

**`THRESHOLD`**: Maximum allowed performance ratio
- `1.00` - Must match exactly (unrealistic)
- `1.05` - 5% overhead max (excellent)
- `1.10` - 10% overhead max (good)
- `1.15` - 15% overhead max (acceptable)
- `1.20` - 20% overhead max (target for initial implementations)
- `1.50` - 50% overhead max (only for complex features with huge DX wins)

**`benchmark.sh`**: Compiles ALL reference implementations and compares with hyperfine
```bash
#!/bin/bash
set -e

# Compile Koru (emits Zig, then compile with Zig)
koruc input.kz -o koru_output.zig
zig build-exe koru_output.zig -O ReleaseFast -femit-bin=koru

# Compile ALL reference implementations
zig build-exe reference/baseline.zig -O ReleaseFast -femit-bin=baseline-zig
gcc reference/reference.c -O3 -march=native -o baseline-c
rustc reference/reference.rs -C opt-level=3 -C target-cpu=native -o baseline-rs

# Benchmark ALL implementations together
hyperfine --export-json results.json \
    --warmup 3 \
    --min-runs 10 \
    --style full \
    './baseline-c 50000' \
    './baseline-rs 50000' \
    './baseline-zig 50000' \
    './koru 50000'
```

**This shows context:**
- How does Koru compare to C? (gold standard)
- How does Koru compare to Rust? (modern systems language)
- How does Koru compare to Zig? (our compilation target)
- Is Koru's gap to Zig similar to Zig's gap to C? (overhead analysis)

**`post.sh`**: Validates performance
```bash
#!/bin/bash
# Parse results, calculate ratio, compare to threshold
# Exit 0 if pass, 1 if fail
```

---

## Current Benchmarks

### 2101_nbody - N-body Gravitational Simulation
**Tests**: Float arithmetic, loop optimization, numerical computation
**Target**: Within 10-15% of Zig
**Koru Advantage**: Event composition compiles to tight loops
**Status**: 📝 TODO

### 2102_fannkuch_redux - Array Permutations
**Tests**: Array indexing, integer operations, state manipulation
**Target**: Within 15% of Zig
**Koru Advantage**: Zero-cost event dispatch for state changes
**Status**: 📝 TODO

### 2103_binary_trees - Memory Allocation Stress
**Tests**: Tree allocation/deallocation, memory management
**Target**: Within 25% of Zig (initial), improve to 15%
**Koru Advantage**: Phantom types track ownership, guide optimization
**Status**: 📝 TODO

### 2104_mandelbrot - Parallel Computation
**Tests**: Complex number math, pixel-by-pixel computation
**Target**: Within 15% of Zig (sequential), future: parallel speedup
**Koru Advantage**: Pure functions enable auto-parallelization
**Status**: 📝 TODO

### 2105_fasta - Sequential Generation
**Tests**: Sequential I/O, string generation, file writing
**Target**: Within 10% of Zig
**Koru Advantage**: Clean abstraction with zero overhead
**Status**: 📝 TODO

---

## Running Benchmarks

**⚠️ NOTE: These benchmarks are OPTIONAL (no MUST_RUN marker)**

Like `2004_rings_vs_channels`, these benchmarks don't run automatically in CI. They're opt-in for performance tracking.

### Via Regression Suite
```bash
# Run all language shootout benchmarks
./run_regression.sh 21

# Run specific benchmark
./run_regression.sh 2101
```

**But since they have no MUST_RUN marker, you must run them explicitly!**

### Manually
```bash
cd tests/regression/2100_LANGUAGE_SHOOTOUT/2101_nbody

# Compile Koru version
koruc input.kz -o koru_output.zig

# Run benchmark
bash benchmark.sh

# Check if performance is within threshold
bash post.sh
```

---

## Performance Tracking

Results are tracked in the snapshot system:
```json
{
  "benchmarks": {
    "2101_nbody": {
      "koru_time_ms": 123.4,
      "baseline_time_ms": 98.7,
      "ratio": 1.25,
      "threshold": 1.20,
      "status": "REGRESSION",
      "overhead_percent": 25.0
    }
  }
}
```

### View Performance Report
```bash
./scripts/benchmark-report.js
```

Shows:
- Current status of all benchmarks
- Performance trends across commits
- Which benchmarks need optimization
- Impact of compiler passes on each benchmark

---

## Adding New Benchmarks

1. **Choose benchmark** from [benchmarksgame-team](https://benchmarksgame-team.pages.debian.net/benchmarksgame/)
   - Prefer "insignificant I/O" category (more CPU-focused)
   - Look for benchmarks that test interesting characteristics

2. **Study reference implementations**
   - Understand the algorithm
   - Note optimization techniques
   - Check edge cases

3. **Implement in Koru** (`input.kz`)
   - Start with **correctness** (verify output matches)
   - Use idiomatic Koru patterns
   - Don't hand-optimize yet (let compiler do it!)

4. **Add reference implementations**
   - `baseline.zig` - Hand-optimized Zig (primary comparison)
   - `reference.c` - C version (for reference)
   - Document source/license

5. **Set threshold**
   - Start with `1.20` (within 20%)
   - Measure actual performance
   - Tighten as optimizations improve

6. **Create benchmark scripts**
   - `benchmark.sh` - Run hyperfine
   - `post.sh` - Validate threshold
   - `expected.txt` - Correct output

7. **Document**
   - `README.md` - What does this test?
   - What Koru features does it exercise?
   - What optimizations should help?

---

## Requirements

These tools must be installed:

### hyperfine - Benchmark runner
```bash
# macOS
brew install hyperfine

# Linux
cargo install hyperfine
```

### jq - JSON parser (for post.sh)
```bash
# macOS
brew install jq

# Linux
apt install jq
```

### bc - Calculator (for ratio math)
```bash
# Usually pre-installed on Unix systems
```

---

## Interpreting Results

### ✅ Ratio < 1.0 (Faster!)
Koru is faster than baseline!
- Could be measurement noise → re-run with more iterations
- Could be baseline is suboptimal → improve baseline
- Could be Koru did something clever → document and celebrate! 🎉

### ✅ Ratio ≈ 1.0 (Perfect!)
Koru matches hand-optimized code. This is the dream!

### ⚠️ Ratio < Threshold (Acceptable)
Within threshold, but has overhead. Room for improvement.
- Document current ratio
- Note optimization opportunities
- Tighten threshold as compiler improves

### ❌ Ratio > Threshold (Regression!)
Performance is unacceptable. Investigate:
1. Check emitted code (`koru_output.zig`)
2. Compare to baseline side-by-side
3. Look for extra allocations, calls, bounds checks
4. Identify missing optimizations
5. **Fix compiler, don't relax threshold!**

---

## Optimization Strategy

When a benchmark fails threshold:

1. **Understand WHY**
   - Compare emitted Zig to baseline Zig
   - What's different?
   - Extra function calls? Allocations? Bounds checks?

2. **Categorize the issue**
   - Missing optimization (fusion, inlining, etc.)
   - Suboptimal code generation
   - Runtime overhead (allocator, etc.)

3. **Fix systematically**
   - Implement optimization pass
   - Test on benchmark
   - Measure impact
   - Ensure it doesn't break other tests

4. **Document learnings**
   - Note which passes help which benchmarks
   - Update optimization priorities
   - Share findings!

---

## Success Metrics

### Short Term (Month 1)
- ✅ All 5 Phase 1 benchmarks implemented
- ✅ Correctness verified (output matches expected)
- ✅ Baseline measurements recorded
- 🎯 At least 2 benchmarks within threshold

### Medium Term (Month 2-3)
- 🎯 All Phase 1 benchmarks within threshold
- 🎯 Performance tracking integrated
- 🎯 Clear roadmap for optimization priorities
- 🎯 At least 1 benchmark faster than baseline

### Long Term (Month 6+)
- 🎯 All benchmarks within 10% of hand-optimized code
- 🎯 Several benchmarks faster than naive C/Zig
- 🎯 Documented optimization impact per benchmark
- 🏆 Koru is competitive with established systems languages!

---

## Philosophy Quotes

*"Performance is a feature."* - 2000_PERFORMANCE/README.md

*"Prove it, don't claim it."* - PERFORMANCE.md

*"Be within 20% of C/Zig, then optimize to beat them."* - This README

**Let's make Koru FAST!** 🔥

