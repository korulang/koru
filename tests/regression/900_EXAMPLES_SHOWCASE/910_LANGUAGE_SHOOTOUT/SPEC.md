# Language Shootout Benchmarks - Technical Specification

## Overview

This specification defines how Computer Language Benchmarks Game tests are implemented in Koru, measured, and validated.

---

## Benchmark Integrity - CRITICAL PRINCIPLE

### ⚠️ NO CHEATING WITH GIANT ZIG PROCS

**These benchmarks test Koru's EVENT-DRIVEN ARCHITECTURE, not "can we call Zig code".**

**WRONG Approach (Dishonest):**
```koru
// ❌ BAD: Wrapping a huge Zig proc
~event run_nbody { n: u32 }
| done {}

~proc run_nbody {
    // 500 lines of Zig code doing everything...
    const result = hugeZigFunction(n);
    return .{ .done = .{} };
}
```

**RIGHT Approach (Honest):**
```koru
// ✅ GOOD: Proper event decomposition
~event advance_bodies { bodies: []Body, dt: f64 }
| advanced { bodies: []Body }

~event calculate_energy { bodies: []Body }
| result { energy: f64 }

~proc advance_bodies {
    // Small, focused Zig implementation
    for (bodies) |*body| {
        body.x += dt * body.vx;
        // ... focused logic ...
    }
    return .{ .advanced = .{ .bodies = bodies } };
}
```

### What We're Actually Testing

**YES - These are valid tests:**
- ✅ Event dispatch overhead (should be zero)
- ✅ Event composition patterns (flow orchestration)
- ✅ Whether Koru events compile to equivalent code as direct calls
- ✅ Multi-event flows vs monolithic functions
- ✅ Koru's abstraction cost (should be zero)

**NO - These are NOT valid tests:**
- ❌ "Koru can call fast Zig code" (meaningless)
- ❌ Giant procs wrapped in single events (defeats the purpose)
- ❌ Bypassing Koru's event model (dishonest)

### Implementation Guidelines

1. **Decompose into events with single responsibility**
   - Each event should do ONE clear thing
   - Multiple small events > one giant event
   - Match natural problem decomposition

2. **Use flows to orchestrate events**
   - Show that event composition has zero cost
   - Prove flow chaining compiles to straight-line code

3. **Proc implementations should be focused**
   - Small, focused Zig code (not 500-line monsters)
   - Each proc corresponds to its event's responsibility
   - Readable, maintainable

4. **We're proving Koru's abstraction is zero-cost**
   - NOT proving "we can call fast code"
   - NOT proving "we can avoid Koru features"
   - YES proving "Koru events compile to equivalent code"

## Benchmark Selection Criteria

### Include Benchmarks That:
- ✅ Test computational performance (not just I/O)
- ✅ Have well-defined correct output (deterministic)
- ✅ Exercise specific language characteristics
- ✅ Can be decomposed into multiple focused events
- ✅ Can be implemented in pure Koru (no complex external deps)
- ✅ Benefit from compiler optimizations we plan to implement
- ✅ Showcase event-driven architecture advantages

### Exclude Benchmarks That:
- ❌ Require regex libraries (until we have comptime regex)
- ❌ Require arbitrary precision math (until we have bigint)
- ❌ Are purely I/O bound (doesn't test compiler quality)
- ❌ Require threading (until we have concurrency model)
- ❌ Have non-deterministic output
- ❌ Cannot be sensibly decomposed into events (monolithic only)

---

## Test Structure

### Required Files

#### `input.kz` - Koru Implementation
- Must be idiomatic Koru code
- Should NOT hand-optimize (let compiler do it)
- Must accept command-line args (if needed)
- Must produce correct output
- Should include comments explaining algorithm

#### `reference/baseline.zig` - Primary Comparison Target
- Hand-optimized Zig implementation
- This is what Koru **should** compile to
- Must be clean, readable, well-commented
- Must produce identical output to Koru version
- Should document optimization techniques used

#### `reference/reference.c` - C Reference (Optional)
- From official benchmarks game site
- Documents best-known approach
- Used for understanding, not direct comparison

#### `expected.txt` - Correct Output
- Output from running with standard test input
- Used to verify correctness before measuring performance
- Byte-for-byte identical check

#### `MUST_RUN` - Marker File (NOT INCLUDED)
- **These benchmarks do NOT have MUST_RUN markers**
- Like `2004_rings_vs_channels`, they're **optional** (don't run in CI automatically)
- Must be run explicitly for performance tracking
- This prevents slow benchmarks from blocking regular regression testing

#### `THRESHOLD` - Performance Target
- Single floating-point number (e.g., `1.15`)
- Maximum allowed ratio: `koru_time / baseline_time`
- Start with `1.20`, tighten as compiler improves

#### `benchmark.sh` - Benchmark Script
- Compiles both Koru and baseline versions
- Runs `hyperfine` to measure performance
- Exports results to `results.json`
- Includes warmup runs to stabilize measurements

#### `post.sh` - Validation Script
- Parses `results.json`
- Calculates performance ratio
- Compares to `THRESHOLD`
- Exits 0 (pass) or 1 (fail) with clear message

#### `README.md` - Benchmark Documentation
- What does this benchmark test?
- What computational characteristics?
- What Koru features does it exercise?
- What compiler optimizations should help?
- Performance history/trends

---

## Performance Thresholds

### Threshold Philosophy

**Thresholds are targets, not excuses.**

If a benchmark exceeds threshold:
1. ❌ **DO NOT** relax the threshold
2. ✅ **DO** investigate the performance gap
3. ✅ **DO** fix the compiler or codegen
4. ✅ **DO** document the issue for future work

### Threshold Guidelines

| Ratio | Meaning | When to Use |
|-------|---------|-------------|
| 1.00 | Perfect match | Unrealistic (measurement noise) |
| 1.05 | 5% overhead | Excellent performance |
| 1.10 | 10% overhead | Good performance |
| 1.15 | 15% overhead | Acceptable for initial work |
| 1.20 | 20% overhead | Target for Phase 1 implementations |
| 1.30 | 30% overhead | Temporary, requires optimization plan |
| 1.50 | 50% overhead | Only if feature has massive DX benefit |

### Setting Thresholds

**For new benchmarks:**
1. Implement in Koru (focus on correctness)
2. Implement baseline in Zig (hand-optimized)
3. Run benchmark, measure actual ratio
4. Set threshold = `max(1.20, actual_ratio * 1.05)`
   - Never lower than 1.20 initially
   - Allow 5% margin above current performance
5. Document current ratio and threshold
6. Create optimization plan to reach 1.10 or better

**As compiler improves:**
- Tighten thresholds to match actual performance
- Update in small increments (0.05 at a time)
- Document which optimizations enabled tightening

---

## Benchmark Categories

### Insignificant I/O (Priority 1)
Pure computation, minimal I/O. Best for measuring compiler quality.

**Examples:**
- n-body simulation (floating-point math)
- fannkuch-redux (array manipulation)
- spectral-norm (matrix operations)

**Characteristics:**
- CPU-bound
- Deterministic
- Directly tests codegen quality

### Significant I/O (Priority 2)
Mix of computation and I/O. Tests end-to-end performance.

**Examples:**
- mandelbrot (computation + file write)
- fasta (generation + I/O)
- k-nucleotide (hash table + I/O)

**Characteristics:**
- Tests both computation and I/O
- More realistic
- Harder to isolate compiler performance

### Contentious (Priority 3)
Different approaches, library-dependent. Defer until we have necessary libs.

**Examples:**
- binary-trees (GC-sensitive)
- pidigits (arbitrary precision)
- regex-redux (regex library)

**Characteristics:**
- Library/runtime dependent
- Less about compiler, more about ecosystem
- Useful for completeness, not core validation

---

## Measurement Protocol

### Compilation

**ALL reference implementations are compiled and compared** (like rings-benchmark approach):

```bash
# Compile Koru (emits Zig, then compile)
koruc input.kz -o koru_output.zig
zig build-exe koru_output.zig -O ReleaseFast -femit-bin=koru

# Compile Zig baseline
zig build-exe reference/baseline.zig -O ReleaseFast -femit-bin=baseline-zig

# Compile C reference (if present)
gcc reference/reference.c -O3 -march=native -o baseline-c

# Compile Rust reference (if present)
rustc reference/reference.rs -C opt-level=3 -C target-cpu=native -o baseline-rs
```

**Key Principles:**
- Equivalent optimization flags across languages
- Same problem size for all
- Fair comparison (no language gets special treatment)

### Execution

Use `hyperfine` to compare **ALL implementations** side-by-side:

```bash
hyperfine \
    --export-json results.json \
    --warmup 3 \
    --min-runs 10 \
    --style full \
    --show-output \
    './baseline-c N' \
    './baseline-rs N' \
    './baseline-zig N' \
    './koru N'
```

**This shows:**
- How Koru compares to C (gold standard)
- How Koru compares to Rust (modern systems language)
- How Koru compares to Zig (our codegen target)
- Whether Koru's event abstraction has overhead

**Parameters:**
- `--warmup 3`: Discard first 3 runs (cache warming)
- `--min-runs 10`: Minimum 10 samples (statistical confidence)
- `--style full`: Show detailed statistics
- `N`: Problem size (from benchmark spec)

**Example Output:**
```
Benchmark 1: ./baseline-c 50000
  Time (mean ± σ):      41.2 ms ±   0.4 ms

Benchmark 2: ./baseline-rs 50000
  Time (mean ± σ):      41.8 ms ±   0.5 ms

Benchmark 3: ./baseline-zig 50000
  Time (mean ± σ):      42.1 ms ±   0.3 ms

Benchmark 4: ./koru 50000
  Time (mean ± σ):      48.5 ms ±   0.6 ms

Summary
  './baseline-c 50000' ran
    1.01 ± 0.02 times faster than './baseline-rs 50000'
    1.02 ± 0.01 times faster than './baseline-zig 50000'
    1.18 ± 0.02 times faster than './koru 50000'
```

This gives us **context**: Is the gap Koru→Zig the same as Zig→C? Are we in the ballpark?

### Validation

```bash
# 1. Verify correctness FIRST
./koru N > actual.txt
diff -u expected.txt actual.txt || exit 1

# 2. Measure performance
bash benchmark.sh

# 3. Check threshold
bash post.sh
```

**Order matters:** Correctness before performance!

---

## Expected Output Format

### benchmark.sh Output
```
Benchmark 1: ./baseline 50000
  Time (mean ± σ):      42.3 ms ±   0.5 ms    [User: 41.8 ms, System: 0.4 ms]
  Range (min … max):    41.5 ms …  43.2 ms    10 runs

Benchmark 2: ./koru 50000
  Time (mean ± σ):      48.7 ms ±   0.7 ms    [User: 48.1 ms, System: 0.5 ms]
  Range (min … max):    47.6 ms …  49.8 ms    10 runs

Summary
  './baseline 50000' ran
    1.15 ± 0.02 times faster than './koru 50000'
```

### post.sh Output (PASS)
```
Performance Results:
  Baseline (Zig): 42.3ms ± 0.5ms
  Koru:           48.7ms ± 0.7ms
  Ratio:          1.1513x
  Threshold:      1.2000x

✅ Performance within threshold
   Overhead: 15.1%
   Margin:   4.9% below threshold
```

### post.sh Output (FAIL)
```
Performance Results:
  Baseline (Zig): 42.3ms ± 0.5ms
  Koru:           55.2ms ± 0.8ms
  Ratio:          1.3050x
  Threshold:      1.2000x

❌ PERFORMANCE REGRESSION!
   Koru is 1.3050x slower than baseline
   Threshold is 1.2000x
   Exceeded by: 10.5%

Action Required:
1. Check emitted code: koru_output.zig
2. Compare to baseline: reference/baseline.zig
3. Identify missing optimizations
4. Fix compiler, do NOT relax threshold
```

---

## Correctness Verification

### Primary Check: Output Comparison
```bash
./koru N > actual.txt
diff -u expected.txt actual.txt
```

Must match **byte-for-byte**. No tolerance for floating-point variance.

### How to Generate expected.txt

1. Run official reference implementation (C/Rust)
2. Verify output is correct (matches problem spec)
3. Save as `expected.txt`
4. Koru output must match exactly

### Handling Floating-Point

For benchmarks with floating-point output:
- Use **exact** comparison (not approximate)
- This is deliberate: Koru should produce identical results
- Any variance indicates potential numerical instability

---

## Benchmark Inputs

### Standard Inputs

Each benchmark has a "standard input" size used for testing:

| Benchmark | Small (test) | Medium (CI) | Large (manual) |
|-----------|--------------|-------------|----------------|
| n-body | 1000 | 50000 | 5000000 |
| fannkuch-redux | 7 | 10 | 12 |
| binary-trees | 10 | 16 | 21 |
| mandelbrot | 200 | 4000 | 16000 |
| fasta | 1000 | 1000000 | 25000000 |

**Usage:**
- Small: Quick smoke test (< 1 second)
- Medium: CI/regression (1-10 seconds)
- Large: Manual optimization work (10+ seconds)

### Configuring Inputs

In `benchmark.sh`:
```bash
# Use Medium size for CI
SIZE=50000

hyperfine \
    './baseline $SIZE' \
    './koru $SIZE'
```

---

## Optimization Tracking

### Document Optimization Impact

For each benchmark, track which optimizations help:

```markdown
## Optimization History

| Date | Commit | Optimization | Before | After | Improvement |
|------|--------|-------------|--------|-------|-------------|
| 2024-01-15 | abc123 | Inline small events | 1.25x | 1.18x | 5.6% |
| 2024-01-20 | def456 | Loop unrolling | 1.18x | 1.12x | 5.1% |
| 2024-02-01 | ghi789 | SIMD autovec | 1.12x | 1.05x | 6.3% |
```

### Priority Guidance

Use benchmark results to guide compiler work:

**If multiple benchmarks fail on same issue:**
→ High priority (systemic problem)

**If one benchmark fails uniquely:**
→ Lower priority (edge case)

**If optimization helps multiple benchmarks:**
→ Implement it! High ROI

**If optimization helps only one benchmark:**
→ Consider carefully (may over-specialize)

---

## Reference Implementation Sources

### Official Sources
- C implementations: https://benchmarksgame-team.pages.debian.net/benchmarksgame/
- License: Revised BSD license (permissive)

### Our Baseline Implementations
- Zig baselines: Hand-written, optimized but readable
- Must be equivalent algorithm to Koru version
- Document in comments what optimizations are used

### Attribution
Always include source attribution in reference files:
```zig
// Based on: https://benchmarksgame-team.pages.debian.net/benchmarksgame/program/nbody-gcc-1.html
// License: Revised BSD
// Adapted to Zig by: [name]
// Date: [date]
```

---

## CI Integration

### Regression Test Integration

Language shootout benchmarks run as part of normal regression suite:

```bash
./run_regression.sh 21
```

### CI Behavior

**On success:**
- ✅ All benchmarks within threshold
- Report performance metrics
- Update snapshot with current ratios

**On failure:**
- ❌ One or more benchmarks exceeded threshold
- Show performance regression details
- Block merge until fixed
- Require investigation and fix

### Performance Tracking

CI records performance history:
```bash
./scripts/save-snapshot.js --benchmarks
```

Stores:
- Current ratio for each benchmark
- Trend (improving/regressing/stable)
- Which commit last changed performance significantly

---

## Adding New Benchmarks - Checklist

- [ ] Choose benchmark from official game
- [ ] Verify it meets selection criteria
- [ ] Assign next available number (210X)
- [ ] Create directory structure
- [ ] Implement `input.kz` (focus on correctness)
- [ ] Verify output matches expected
- [ ] Implement `reference/baseline.zig`
- [ ] Add `reference/reference.c` (from official site)
- [ ] Create `expected.txt` from reference output
- [ ] Write `benchmark.sh` script
- [ ] Write `post.sh` validation script
- [ ] Set `THRESHOLD` (start with 1.20)
- [ ] Add `MUST_RUN` marker
- [ ] Document in local `README.md`
- [ ] Test locally: `./run_regression.sh 210X`
- [ ] Update category README with benchmark status
- [ ] Commit with message: "Add 210X_benchmark_name to language shootout suite"

---

## Future Enhancements

### Planned Features
- [ ] Automated threshold tightening (based on trend)
- [ ] Performance dashboard (visualize trends)
- [ ] Comparative reports (Koru vs C vs Rust vs Zig)
- [ ] Integration with benchmark game leaderboard
- [ ] Binary size tracking (not just speed)
- [ ] Memory usage profiling
- [ ] Parallel versions (when we have concurrency)

### Stretch Goals
- Submit Koru to official benchmarks game
- Beat C on at least 3 benchmarks
- Achieve <5% overhead on all numeric benchmarks
- Document case studies of optimization impact

---

**Let's make Koru competitive!** 🚀
