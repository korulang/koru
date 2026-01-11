# 320_052: Expand with Continuations

**STATUS: PASSING**

This test demonstrates `[expand]` support for events with branches/continuations.

## How It Works

1. **Template produces the switch expression**: The template defines inline Zig code that returns a union value (the result of the branching logic).

2. **Emitter generates the switch**: When a flow has both `inline_body` (from expand) AND continuations, the emitter generates:
   ```zig
   const __expand_result = <inline_body>;
   switch (__expand_result) {
       .branch1 => |binding| { <continuation body> },
       .branch2 => { <continuation body> },
   }
   ```

3. **Continuations become switch arms**: The user's continuation bodies are emitted as the switch arm bodies.

## Pattern

```koru
// Template produces the expression that returns the union
~std.template:define(name: "maybe") {
    blk: {
        const Result = union(enum) { some: T, none: void };
        if (condition) break :blk Result{ .some = value };
        else break :blk Result{ .none = {} };
    }
}

// Event with branches
~[norun|expand]pub event maybe { ... }
| some { ... }
| none {}

// Usage - branches become switch arms
~maybe(expr: value)
| some s |> handle_some(s)
| none |> handle_none()
```

## Limitations

- The flow checker doesn't recognize `binding.field` as using `binding`, so bindings that are only accessed via field access will trigger "unused binding" errors. Use `| some _ |>` for discarded bindings.

## Implementation

- `transform_pass_runner.zig`: Keeps continuations when setting inline_body for expand
- `emitter_helpers.zig`: Detects inline_body + continuations pattern, generates switch
