# 2101b_nbody_granular - N-Body (ULTRA-GRANULAR VERSION)

## What This Tests

**This is the extreme single-responsibility version of 2101_nbody.**

It proves that MAXIMUM event granularity with deep subflow nesting still compiles to zero-cost code.

### Comparison with 2101

| Aspect | 2101 (Moderate) | 2101b (Ultra-Granular) |
|--------|-----------------|------------------------|
| Events | 8 | ~25 |
| Subflows | 0 | 4 |
| Event Size | Medium operations | Tiny single-responsibility ops |
| Purpose | Proper decomposition | EXTREME decomposition |
| Expected Performance | ~1.06x slower than C | **Should match 2101!** |

**What We're Proving:**
- Subflow composition is zero-cost (deep nesting doesn't add overhead)
- Extreme granularity is free (25+ tiny events = same performance as 8 medium events)
- Single responsibility scales (decompose as much as you want without penalty)
- Event abstraction truly compiles away (not just "mostly" away)

## The Algorithm

Same as 2101: N-body gravitational simulation with 5 bodies.

1. **Initialize** - Create 5 bodies (Sun, Jupiter, Saturn, Uranus, Neptune)
2. **Offset momentum** - Adjust sun's velocity so system momentum is zero
3. **Calculate energy** - Compute total kinetic + potential energy (baseline)
4. **Advance N times:**
   - Calculate gravitational forces between all pairs
   - Update velocities based on forces
   - Update positions based on velocities
5. **Calculate energy** - Final energy (shows energy conservation)

## Ultra-Granular Event Decomposition

### 1. Planetary Initialization (6 events + 1 subflow)
```koru
~event create_sun {}           // Just create sun
~event create_jupiter {}       // Just create Jupiter
~event create_saturn {}        // Just create Saturn
~event create_uranus {}        // Just create Uranus
~event create_neptune {}       // Just create Neptune
~event assemble_solar_system { sun, jupiter, saturn, uranus, neptune }

// Subflow composes planet creation
~subflow initialize_system {}
| initialized { bodies: [5]Body }
```

**vs 2101:** Single `initialize_bodies` event

### 2. Momentum Offset (4 events + 1 subflow)
```koru
~event calculate_momentum_x { bodies }  // Just X momentum
~event calculate_momentum_y { bodies }  // Just Y momentum
~event calculate_momentum_z { bodies }  // Just Z momentum
~event apply_sun_offset { bodies, px, py, pz }

// Subflow composes momentum calculation
~subflow offset_momentum { bodies }
| adjusted { bodies }
```

**vs 2101:** Single `offset_momentum` event

### 3. Energy Calculation (5 events + 1 subflow)
```koru
~event calculate_single_kinetic { body }      // KE for one body
~event sum_kinetic_energies { bodies }        // Total KE
~event calculate_pair_potential { b1, b2 }    // PE for one pair
~event sum_potential_energies { bodies }      // Total PE
~event combine_energies { ke, pe, bodies }    // KE + PE

// Subflow composes energy calculation
~subflow calculate_total_energy { bodies }
| result { energy, bodies }
```

**vs 2101:** Single `calculate_energy` event

### 4. Gravitational Interactions (5 events + 1 subflow)
```koru
~event calculate_distance_vector { b1, b2 }           // dx, dy, dz
~event calculate_distance_scalar { dx, dy, dz }       // sqrt(dx² + dy² + dz²)
~event calculate_gravitational_magnitude { distance, dt } // dt / distance³
~event update_body_pair_velocities { b1, b2, dx, dy, dz, mag }
~event calculate_all_interactions { bodies, dt }      // Loop over all pairs

// Subflow for ONE PAIR (demonstrates deep nesting!)
~subflow process_body_pair { b1, b2, dt }
| updated { b1, b2 }
```

**vs 2101:** Single `calculate_interactions` event

This subflow demonstrates **deep nesting** - a 4-level event chain composed into a subflow that SHOULD compile to straight-line code.

### 5. Position Updates (2 events)
```koru
~event update_single_position { body, dt }    // Update one body
~event update_all_positions { bodies, dt }    // Update all bodies
```

**vs 2101:** Single `update_positions` event

### 6. Utilities (3 events - same as 2101)
```koru
~event print_energy { energy, bodies }
~event simulation_step { bodies, i, n }
~event parse_args {}
```

## What This Proves

**If 2101b achieves the same performance as 2101 and the Zig baseline:**

✅ **Subflow composition is zero-cost** - Deep nesting doesn't add runtime overhead
✅ **Extreme granularity is free** - 25+ tiny events compile to same code as 8 medium events
✅ **Single responsibility scales infinitely** - You can decompose as much as makes sense
✅ **Event abstraction truly disappears** - Not just "mostly compiles away", but COMPLETELY

**This is the ultimate test of zero-cost abstraction.**

If the compiler can take this:
```koru
~subflow process_body_pair { b1, b2, dt }
  ~calculate_distance_vector(b1, b2)
  |> calculate_distance_scalar(dx, dy, dz)
  |> calculate_gravitational_magnitude(distance, dt)
  |> update_body_pair_velocities(b1, b2, dx, dy, dz, mag)
```

And turn it into code as fast as:
```zig
const dx = b1.x - b2.x;
const distance = @sqrt(dx*dx + dy*dy + dz*dz);
const mag = dt / (distance * distance * distance);
b1.vx -= dx * b2.mass * mag;
```

Then we've proven that event-driven architecture is NOT just "good enough" - it's ACTUALLY zero-cost.

## Performance Expectations

### Threshold: 1.20x (Same as 2101)

**Success looks like:**
```
C (gcc -O3):        3.2ms  [gold standard]
Zig (ReleaseFast):  3.2ms  [hand-optimized baseline]
Koru 2101:          3.0ms  [8 events, moderate decomposition]
Koru 2101b:         3.0ms  [25+ events, extreme decomposition] ✅

2101b / 2101:  1.00x  ✅ No penalty for extreme decomposition!
2101b / Zig:   1.08x  ✅ Within threshold!
```

**What would FAIL this test:**
```
Koru 2101b:  4.5ms  [significantly slower than 2101]

2101b / 2101:  1.50x  ❌ Subflow overhead! Event abstraction NOT zero-cost!
```

## Running This Benchmark

**⚠️ NOTE: This benchmark is OPTIONAL (no MUST_RUN marker)**

### Via Regression Suite
```bash
# Run just this benchmark
./run_regression.sh 2101b

# Compare with 2101
./run_regression.sh 2101 && ./run_regression.sh 2101b
```

### Manually
```bash
cd tests/regression/2100_LANGUAGE_SHOOTOUT/2101b_nbody_granular

# Full benchmark suite (same infrastructure as 2101)
bash benchmark.sh

# Check threshold
bash post.sh
```

### What This Uses

**Same reference implementations as 2101:**
- `reference/reference.c` - Official C reference (generates expected.txt)
- `reference/baseline.zig` - Hand-optimized Zig target

**Only difference:**
- `input.kz` - Ultra-granular Koru implementation with subflows

## Correctness Verification

**Expected output for N=50000:**
```
-0.169075164
-0.169078071
```

Must match 2101 and all reference implementations exactly.

## Success Criteria

**Correctness:**
- ✅ Output matches expected.txt exactly
- ✅ Energy conservation within tolerance

**Performance (THE CRITICAL TEST):**
- 🎯 **Within 1.00-1.05x of 2101** (no penalty for extreme decomposition!)
- 🎯 Within 1.20x of Zig baseline (same threshold as 2101)
- 🎯 Comparable to C reference

**Code Quality:**
- ✅ Maximum event granularity (each event does ONE thing)
- ✅ Deep subflow nesting (4+ level chains)
- ✅ Demonstrates composition scales without penalty

## If This Passes...

**We've proven something extraordinary:**

Most languages with abstraction layers (object-oriented, functional, async/await) have a cost:
- Virtual dispatch costs cycles
- Function call overhead matters
- Abstractions leak performance

**If 2101b matches 2101:**
- Koru's event abstraction has NO COST
- You can write maximally decomposed, maximally readable code
- The compiler turns it into maximally optimized machine code
- Zero-cost abstraction isn't a goal - it's a REALITY

## Related Benchmarks

- **2101_nbody** - Moderate decomposition version (comparison baseline)
- **2102_fannkuch_redux** - Different algorithm (array manipulation)
- **2004_rings_vs_channels** - Concurrency benchmark (different focus)

## References

- [Computer Language Benchmarks Game](https://benchmarksgame-team.pages.debian.net/benchmarksgame/)
- [N-body description](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/nbody.html)
- [2101_nbody NOTES.md](../2101_nbody/NOTES.md) - The moderate version
- [Category README](../README.md)
- [Category SPEC](../SPEC.md)
