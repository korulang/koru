# TODO: Comptime Program Return

## Feature Description

Allow `[comptime]` events to return a modified `Program` that becomes the new AST.

Currently:
- `[comptime]` events can RECEIVE `program: *const Program` (injection works)
- `[comptime|transform]` events can modify AST by replacing invocations

Missing:
- `[comptime]` events returning `program: *const Program` in their output branch

## Use Case: Route Collector

```koru
~[comptime] event collect_routes { program: *const Program, allocator: Allocator }
| done { program: *const Program }

~[comptime] proc collect_routes {
    // 1. Walk AST, find all [norun] route declarations
    // 2. Generate routing table as new AST item
    // 3. Return program with routing table added
    const routing_table = generateRoutingTable(program, allocator);
    const new_program = ast_functional.addItem(allocator, program, routing_table);
    return .{ .done = .{ .program = new_program } };
}
```

## Conceptual Difference

| Annotation | Purpose | Scope |
|------------|---------|-------|
| `[comptime\|transform]` | Replace specific invocations | Surgical - one invocation at a time |
| `[comptime]` + Program return | Modify entire AST | Holistic - cross-cutting changes |

## Implementation Notes

1. In `compiler.kz` (evaluate_comptime pass):
   - Check if comptime event's done branch has a `program` field
   - If so, use the returned Program as `ctx.ast` going forward

2. In generated code:
   - The `comptime_flowN()` function needs to return the Program
   - `comptime_main()` needs to chain Programs through multiple flows

3. Use `ast_functional.zig` for safe, immutable transformations

## Status

- [x] Detect Program in comptime event output
- [x] Thread returned Program through comptime_main
- [x] Update ctx.ast with returned Program
- [ ] Test with actual AST modification
