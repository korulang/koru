# 2101c_nbody_extreme - N-Body (EVENT-DRIVEN NESTED LOOPS)

## What This Tests

**This is the EXTREME version that decomposes NESTED LOOPS into event-driven recursion.**

This is the ultimate test: Can we replace imperative loop constructs with purely event-driven iteration without performance penalty?

### Comparison Across Versions

| Aspect | 2101 | 2101b | 2101c (THIS) |
|--------|------|-------|--------------|
| Events | 8 | ~25 | ~30 |
| Subflows | 0 | 4 | 5 |
| Loop Style | Zig while loops | Zig while loops | **Recursive events** |
| Nested Loops | `while (i) { while (j) { ... } }` | Same | **Event-driven iteration** |
| Purpose | Moderate decomposition | Extreme decomposition | **Loop decomposition** |

### The Critical Difference

**2101 & 2101b:**
```zig
~proc calculate_all_interactions {
    var i: usize = 0;
    while (i < bodies.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < bodies.len) : (j += 1) {
            // process pair (i, j)
        }
    }
}
```

**2101c (THIS VERSION):**
```koru
// Decomposed into recursive event iteration!
~calculate_all_interactions = outer_loop_step(bodies, i: 0, dt)
| continue_outer -> inner_loop_step(bodies, i, j: i+1, dt)
    | continue_inner -> update_pair_in_array(bodies, i, j, dt)
        | updated_array -> (recursion to next j)
    | done_inner -> (recursion to next i)
| done_outer -> updated { bodies, dt }
```

## What We're Testing

**Can we replace this:**
```zig
for i in 0..len:
  for j in (i+1)..len:
    update(i, j)
```

**With this:**
```koru
~event outer_loop_step { bodies, i, dt }
| continue_outer | done_outer

~event inner_loop_step { bodies, i, j, dt }
| continue_inner | done_inner

~event update_pair_in_array { bodies, i, j, dt }
| updated_array

// Recursive event composition
```

**And have it compile to the SAME machine code?**

## Event-Driven Loop Decomposition

### New Events for Loop Iteration

1. **`outer_loop_step`** - Check if `i < len`, branch to continue or done
2. **`inner_loop_step`** - Check if `j < len`, branch to continue or done
3. **`update_pair_in_array`** - Process one pair (i, j), update array

### Recursive Flow Structure

The subflow uses:
- **Recursive tail calls** - `@inner_start` jumps back to process next j
- **Nested label management** - Inner loop recursion inside outer loop iteration
- **State threading** - Bodies array threaded through all iterations

This tests whether the compiler can:
- ✅ Recognize tail recursion and compile to loops
- ✅ Optimize away event dispatch overhead in tight loops
- ✅ Handle nested recursion without stack overflow
- ✅ Inline deeply nested event chains

## The Ultimate Question

**If 2101c matches 2101 and 2101b performance:**

Then we've proven something RADICAL:
- Imperative loops are NOT special
- Event-driven recursion can be zero-cost
- You can write purely event-driven code without penalty
- The compiler TRULY erases abstractions

**If 2101c is slower:**

Then we've found the limit:
- Loop iteration has special compiler support
- Recursive events have measurable cost
- There IS a performance cliff for extreme abstraction
- We know where pragmatism beats purity

## Performance Expectations

### Threshold: 1.20x (Same as 2101)

**Best case (zero-cost loop decomposition):**
```
C:       3.2ms
Zig:     3.2ms
2101:    3.0ms  [8 events, Zig loops]
2101b:   3.0ms  [25 events, Zig loops]
2101c:   3.0ms  [30 events, EVENT loops] ✅ SAME!

2101c / 2101b:  1.00x  ✅ Loop decomposition is free!
```

**Realistic case (slight cost for recursion):**
```
2101c:   3.5ms  [slightly slower]

2101c / 2101b:  1.17x  ✅ Still within threshold!
```

**Failure case (abstraction cliff):**
```
2101c:   6.0ms  [significantly slower]

2101c / 2101b:  2.00x  ❌ Recursive events have real cost!
```

## What This Reveals

This benchmark will definitively answer:

1. **Can tail recursion be fully optimized?**
   - If yes → same performance
   - If no → measurable slowdown

2. **Is there a cost to event dispatch in hot loops?**
   - If yes → we'll see it here (10,000+ dispatches per run)
   - If no → proves dispatch is truly zero-cost

3. **Where is the abstraction limit?**
   - 2101: Moderate abstraction → fast
   - 2101b: Extreme abstraction → still fast
   - 2101c: Loop abstraction → ???

4. **Should developers avoid event-driven loops?**
   - If 2101c matches 2101b → No! Use events freely
   - If 2101c is slower → Yes, keep hot loops imperative

## Running This Benchmark

```bash
# Run all three versions for comparison
./run_regression.sh 2101 && ./run_regression.sh 2101b && ./run_regression.sh 2101c

# Or run 2101c alone
./run_regression.sh 2101c

# Or manually
cd tests/regression/2100_LANGUAGE_SHOOTOUT/2101c_nbody_extreme
bash benchmark.sh
```

## Success Criteria

**Correctness:**
- ✅ Output matches expected.txt exactly
- ✅ No stack overflow (recursive events must compile to loops)

**Performance:**
- 🎯 **Within 1.00-1.10x of 2101b** (ideal - no loop decomposition cost)
- 🎯 Within 1.20x of Zig baseline (threshold - still acceptable)
- 📊 Document any gap to understand limits

## Why This Matters

Most event-driven systems avoid loops-as-events because of perceived overhead:
- Erlang/Elixir use recursive functions (tail-call optimization required)
- Async/await systems keep loops imperative
- Actor systems batch work to avoid per-message overhead

**If Koru can do this at zero cost**, it proves:
- Event abstraction can be COMPLETE (not just for high-level flow)
- You don't need escape hatches to imperative code
- The compiler truly understands and optimizes event semantics

## Related Benchmarks

- **2101_nbody** - Moderate decomposition (baseline)
- **2101b_nbody_granular** - Extreme decomposition (but Zig loops)
- **2004_rings_vs_channels** - Concurrency (different abstraction test)

## References

- [Computer Language Benchmarks Game](https://benchmarksgame-team.pages.debian.net/benchmarksgame/)
- [N-body description](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/nbody.html)
- [2101_nbody NOTES.md](../2101_nbody/NOTES.md)
- [2101b_nbody_granular NOTES.md](../2101b_nbody_granular/NOTES.md)
