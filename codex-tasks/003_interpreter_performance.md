# Task 003: Interpreter Performance Optimization

## Status
- [ ] Not Started

## Context

The Koru interpreter can parse and execute Koru continuation chains at runtime. This is the foundation for the wire protocol vision (sending Koru flows over HTTP instead of REST/GraphQL).

Current performance on a benchmark running `~for(0..100)` with 100 `add` dispatches:

| Component | Time | Notes |
|-----------|------|-------|
| Parse only | 36 us | Full compiler parser |
| Execute | ~87 us | Environment setup + flow execution |
| **Total** | 123 us | |
| Python baseline | 39 us | Simple function calls |

**Koru is ~3x slower than Python** for this benchmark. Goal: match or beat Python.

## Files

- `/Users/larsde/src/koru/koru_std/interpreter.kz` - Main interpreter
- `/Users/larsde/src/koru/koru_std/runtime.kz` - Scope registration and dispatch
- `/Users/larsde/src/koru/tests/regression/400_RUNTIME_FEATURES/430_RUNTIME/430_036_interpreter_for_loop/benchmark.kz` - Benchmark
- `/Users/larsde/src/koru/tests/regression/400_RUNTIME_FEATURES/430_RUNTIME/430_036_interpreter_for_loop/benchmark.py` - Python comparison

## Run the Benchmark

```bash
cd tests/regression/400_RUNTIME_FEATURES/430_RUNTIME/430_036_interpreter_for_loop

# Build and run Koru benchmark
/usr/local/bin/koruc benchmark.kz && ./a.out

# Run Python comparison
python3 benchmark.py

# Release build (slightly faster)
zig build -Doptimize=ReleaseFast && ./zig-out/bin/output
```

## Optimization Opportunities

### 1. Environment Reuse (HIGH IMPACT - estimated 20-30 us)

Currently, every execution creates new `Environment` and `ExprBindings`:

```zig
// Current: recreate per iteration
var env = Environment.init(allocator);  // HashMap allocation
defer env.deinit();
var expr_bindings = ExprBindings.init(allocator);
defer expr_bindings.deinit();
```

Add `clear()` methods to reuse:

```zig
// Proposed: reuse with clear
env.clear();
expr_bindings.clear();
```

Files to modify:
- `interpreter.kz`: Add `clear()` to `Environment` and `ExprBindings` structs

### 2. Lighter-Weight Runtime Parser (MEDIUM IMPACT - estimated 10-20 us)

The current parser (`/usr/local/lib/koru/src/parser.zig`) is built for:
- Full error recovery
- Detailed error messages with source locations
- IDE support (lenient mode)
- Complete AST with all metadata

A runtime parser could be simpler:
- Fail-fast on errors (no recovery)
- Minimal AST (only what execution needs)
- No source location tracking
- Simpler lexer

This is a larger change - create a new `runtime_parser.zig` focused on speed.

### 3. Faster Binding Lookup (MEDIUM IMPACT)

Currently using `std.StringHashMap` for bindings. Alternatives:
- Array-based lookup for small binding counts (most flows have <10 bindings)
- Interned string keys
- Pre-computed hashes

### 4. Reduce Allocations in Hot Path (LOW-MEDIUM IMPACT)

In `executeFlow`, the arg evaluation allocates:

```zig
var evaluated_args = try ctx.allocator.alloc(ast.Arg, inv.args.len);
```

Could use a fixed-size stack buffer for small arg counts.

### 5. Expression Evaluator Optimization (LOW IMPACT)

The `evaluateExpr` function parses field access strings like "v.num":

```zig
if (std.mem.indexOf(u8, trimmed, ".")) |dot_pos| {
    const binding_name = trimmed[0..dot_pos];
    const field_name = trimmed[dot_pos + 1..];
    // ...
}
```

Could be faster with pre-parsed expression AST.

## Measurement Guidelines

1. Always run benchmarks multiple times - results vary
2. Use release builds for final comparison: `zig build -Doptimize=ReleaseFast`
3. Report both absolute times AND relative to Python
4. Test with different workloads (simple dispatch, loops, nested flows)

## Success Criteria

- [ ] Match Python performance (39 us) on the loop benchmark
- [ ] Simple dispatch stays under 500 ns
- [ ] No correctness regressions (run existing tests)

## Testing

After any changes, verify:

```bash
# Existing interpreter tests still pass
cd tests/regression/400_RUNTIME_FEATURES/430_RUNTIME/430_035_interpreter_binding_args
/usr/local/bin/koruc input.kz && ./a.out

# For loop test still works
cd ../430_036_interpreter_for_loop
/usr/local/bin/koruc input.kz && ./a.out
```

Expected output for binding args test:
```
[consume] received n = '42'
```

Expected output for for loop test:
```
[print_num] n = 0
[print_num] n = 1
[print_num] n = 2
```
