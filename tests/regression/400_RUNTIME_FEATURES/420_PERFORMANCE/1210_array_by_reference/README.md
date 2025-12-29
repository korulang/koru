# Optimization: Pass Large Arrays By Reference

## The Problem

**Discovered in benchmark 2101_nbody:** Koru is 1.09x slower than C while hand-written Zig is 1.05x slower than C. The 4% gap is caused by unnecessary array copying.

### Current Code Generation (BAD)

When an event takes or returns an array:
```koru
~event process { bodies: [5]Body }
| result { bodies: [5]Body }
```

The compiler generates:
```zig
pub const Input = struct {
    bodies: [5]Body,  // 280 bytes copied on call!
};
pub const Output = union(enum) {
    result: struct {
        bodies: [5]Body,  // 280 bytes copied on return!
    },
};
```

This causes **massive copying overhead** in hot loops where events are called millions of times.

### Baseline Comparison

Hand-written Zig uses **slices** (pass by reference):
```zig
fn advance(bodies: []Body, dt: f64) void {  // Just 16 bytes (ptr + len)
    // Mutate bodies in-place, no copying!
}
```

The slice is 16 bytes (pointer + length) vs 280 bytes for the array copy.

## The Fix

### Option 1: Use Slices
```zig
pub const Input = struct {
    bodies: []const Body,  // 16 bytes - read-only slice
};
pub const Output = union(enum) {
    result: struct {
        bodies: []Body,  // 16 bytes - mutable slice
    },
};
```

**Pros:** Works for any array size, idiomatic Zig
**Cons:** Loses compile-time size information

### Option 2: Use Pointers to Arrays
```zig
pub const Input = struct {
    bodies: *const [5]Body,  // 8 bytes - pointer to const array
};
pub const Output = union(enum) {
    result: struct {
        bodies: *[5]Body,  // 8 bytes - pointer to mutable array
    },
};
```

**Pros:** Keeps size info, minimal overhead (8 bytes)
**Cons:** Requires lifetime management

### Option 3: Smart Heuristic
- Arrays smaller than threshold (e.g., 64 bytes): pass by value (fine to copy)
- Arrays larger than threshold: pass by pointer/slice (avoid copying)

## Performance Impact

In 2101_nbody:
- Current: Koru 1.09x slower than C (array copying overhead)
- Expected after fix: Koru 1.05x slower than C (match Zig baseline)
- **4% performance improvement** from one optimization!

This will compound - as we write more Koru code with arrays, the copying overhead multiplies.

## Implementation

This requires changes to:
1. **Code generator** (`src/emitter.zig` or similar) - detect arrays in event signatures
2. **Flow compiler** - adjust how arrays are passed between events
3. **Type system** - handle pointer/slice types in event signatures

## Testing

1. Compile this test with current compiler
2. Check generated `output_emitted.zig` - should see array copies
3. Run performance comparison
4. After fix: arrays should become slices/pointers
5. Performance should improve measurably

## Related

- **2101_nbody benchmark** - Where this was discovered
- **Zero-cost abstraction goal** - Event composition should be as fast as hand-written code
