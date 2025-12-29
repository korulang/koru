# Verification: Optional Branch Dead Code Elimination

When this test passes, you MUST manually verify that dead code elimination is working.

## What to Check

After the test compiles successfully, examine `output_emitted.zig`:

### 1. The Union Should Have All Branches

```zig
pub const Output = union(enum) {
    success: struct { result: u32 },
    warning: struct { msg: []const u8 },
    debug: struct { details: []const u8 },
};
```

All branches (including optional ones) must be in the union type definition.

### 2. The Handler Should Have ELIMINATED Optional Branches

Search for `pub fn handler` in the process event:

```zig
pub fn handler(e: Input) Output {
    const value = e.value;
    const doubled = value * 2;

    // ❌ THIS CODE SHOULD NOT BE HERE:
    // if (value > 100) {
    //     std.debug.print("[WARNING] Large value: {}\n", .{value});
    //     return .{ .warning = .{ .msg = "Value is large" } };
    // }

    // ❌ THIS CODE SHOULD NOT BE HERE:
    // if (value % 2 == 1) {
    //     std.debug.print("[DEBUG] Odd value: {}\n", .{value});
    //     return .{ .debug = .{ .details = "Value is odd" } };
    // }

    // ✅ ONLY THIS CODE SHOULD REMAIN:
    std.debug.print("Processed: {}\n", .{doubled});
    return .{ .success = .{ .result = doubled } };
}
```

### 3. How to Verify

```bash
# After test passes, check the generated handler:
grep -A 20 "pub fn handler" tests/regression/918_optional_branches/output_emitted.zig

# Should NOT contain:
# - "value > 100"
# - "WARNING"
# - "value % 2 == 1"
# - "DEBUG"

# Should ONLY contain:
# - "doubled = value * 2"
# - "Processed:"
# - "return .{ .success"
```

### 4. Expected Behavior

**Compile-time**:
- Parser accepts `?warning` and `?debug` syntax
- Shape checker allows flows to skip optional branches
- Code generator creates specialized handler with only success path

**Runtime**:
- Only "Processed: 20" and "Processed: 84" printed
- NO "[WARNING]" or "[DEBUG]" output
- Smaller binary (dead code eliminated)

### 5. Full Handler Implementation Test

Create a second handler that DOES use optional branches:

```koru
~process(value: 150)
| success |> _
| warning |> std.debug.print("Got warning: {s}\n", .{msg})

~process(value: 7)
| success |> _
| debug |> std.debug.print("Got debug: {s}\n", .{details})
```

This handler's generated code SHOULD include the warning/debug checks.

## Why This Matters

This proves Koru can do **better than Zig** at zero-cost abstractions:
- Zig unions must have all variants at same size
- Koru can specialize handlers per call site
- Optional branches = true zero-cost
