# BUG: When Clause Is Inside Tap Function, Should Be At Call Site

## Current (WRONG) Implementation:

```zig
fn __tap0(d: anytype) void {
    if (d.result > 50) {  // ← When clause INSIDE tap function
        const nested_result_0 = alert.handler(.{ .result = d.result });
        _ = nested_result_0;
    }
}

// Call site
switch (result) {
    .done => |_tap_payload| {
        __tap0(_tap_payload);  // ← Called unconditionally
        // Terminal
    },
}
```

## Correct Implementation Should Be:

```zig
fn __tap0(d: anytype) void {
    // NO if statement here
    const nested_result_0 = alert.handler(.{ .result = d.result });
    _ = nested_result_0;
}

// Call site
switch (result) {
    .done => |_tap_payload| {
        if (_tap_payload.result > 50) {  // ← When clause at CALL SITE
            __tap0(_tap_payload);
        }
        // Terminal
    },
}
```

## Why This Matters:

1. **Performance**: Condition should be checked BEFORE function call overhead
2. **Semantics**: The when clause filters which events fire taps, not what taps do
3. **Composability**: Tap functions should be pure - the filtering is a property of the observation, not the action

## How to Verify:

Check `output_emitted.zig` and search for `__tap0`. The `if` statement should be at the call site, not in the function body.

## Files to Fix:

- `/Users/larsde/src/koru/koru_std/compiler_bootstrap.kz` lines 1559-1564 (tap function generation)
- All tap injection sites need to emit the when clause check before calling tap
