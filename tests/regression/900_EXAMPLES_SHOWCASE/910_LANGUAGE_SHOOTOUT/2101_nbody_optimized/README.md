# 2101_nbody_optimized - Fair Compiler Flags Comparison

This is an **OPTIMIZED** version of `2101_nbody` with aggressive compiler flags to ensure apples-to-apples comparison.

## Key Differences from 2101_nbody

### Original (2101_nbody)
- **C**: `gcc -O3 -march=native`
- **Zig**: `zig -O ReleaseFast`
- **Rust**: `rustc -C opt-level=3 -C target-cpu=native`
- **Result**: Rust appeared 15-20% faster (UNFAIR - had better flags!)

### This Version (2101_nbody_optimized)
- **C**: `gcc -O3 -march=native -ffast-math -fno-math-errno`
- **Zig**: `zig -O ReleaseFast -mcpu=native` + `@setFloatMode(.optimized)` in source
- **Rust**: `rustc -C opt-level=3 -C target-cpu=native` (unchanged)
- **Result**: Should be much closer (all within ~5%)

## Why This Matters

The original benchmark had Rust winning by a large margin, but this was due to:
1. **CPU features**: Rust got AVX2/FMA via `target-cpu=native`, Zig didn't
2. **Fast-math**: Rust allows FP reassociation, C/Zig were conservative
3. **Aliasing**: Rust's `&mut` gives LLVM noalias hints automatically

With fair flags, we're testing:
- **Koru's event abstraction** vs hand-written code
- **NOT** testing compiler flag differences

## Running

```bash
cd tests/regression/2100_LANGUAGE_SHOOTOUT/2101_nbody_optimized
./benchmark.sh
```

Compare results against `../2101_nbody/results.json` to see the flag impact!
