# Test 202c: Shadowing Validation (Currently Lazy)

## Purpose
This test documents that shadowing validation currently happens in Zig, not the Koru compiler.

## Current Behavior (Lazy Implementation)

### What happens:
1. **Koru parser**: Accepts duplicate binding names (no validation)
2. **Koru compiler**: Generates Zig code with duplicate `|r|` captures
3. **Zig compiler**: Rejects with error:
   ```
   error: capture 'r' shadows capture from outer scope
   ```

### The Test:
```koru
~first(value: 10)
| result r |> second(value: r.num)    // First 'r' binding
    | data r |> show(...)              // Second 'r' binding - DUPLICATE!
```

## Desired Behavior (Future Improvement)

The **Koru compiler** should catch this during validation and produce:

```
Error: Duplicate binding name 'r' in nested continuation
  --> input.kz:38:12
   |
38 |     | data r |> show(outer_val: r.num, inner_val: r.num)
   |            ^ duplicate binding name
   |
33 | | result r |> second(value: r.num)
   |          - 'r' first bound here
   |
   = note: Koru forbids shadowing - use unique binding names like 'r' and 'data_r'
```

## Why This Matters

**Better error messages**:
- Current: Zig error points to generated code (confusing)
- Desired: Koru error points to source .kz file (clear)

**Faster feedback**:
- Current: Error happens during Zig compilation (later)
- Desired: Error happens during Koru validation (earlier)

**Consistency**:
- We validate other things (shapes, labels, imports)
- We should validate bindings too

## Implementation Strategy

Add binding scope validation pass that:
1. Tracks binding names in scope chain
2. Checks each new binding against parent scopes
3. Reports error if duplicate found

This could be added to the shape validation pass or as a separate binding validation pass.

## Status

**Current**: Test expects Zig error (lazy validation)
**Future**: Update expected_error.txt when Koru implements proper validation

The lazy approach is acceptable for now - we do get an error, just not the best one.
