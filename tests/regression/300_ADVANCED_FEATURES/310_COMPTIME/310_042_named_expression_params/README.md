# Named Expression Parameters

## Status: Partially Implemented

## What Works

Event definitions correctly generate Input structs with multiple Expression fields:

```zig
pub const Input = struct {
    expr: []const u8,
    guard: []const u8,  // Named Expression parameter - correct!
    ...
};
```

## What's Broken

Transform invocation only extracts the FIRST Expression and hardcodes it to `.expr`:

```zig
// In generated call_handler_* function:
const expr_opt = extractExprFromArgs(invocation.args);  // Gets first only
const input = handler.Input{
    .expr = expr_text,  // Hardcoded field name
    // guard: ??? never extracted!
};
```

## Fix Required

In `src/main.zig` where transform handlers are generated (~line 2241):

1. Track Expression parameter names (not just `has_expression` boolean)
2. Generate `extractNamedExprFromArgs(args, "guard")` for each named Expression
3. Build Input struct with correct field names

## Use Case

```koru
~operation(1..N, guard: i > 100)
```

The `guard: i > 100` should be captured as a separate Expression, allowing
transforms to interpolate guard conditions into generated code.
