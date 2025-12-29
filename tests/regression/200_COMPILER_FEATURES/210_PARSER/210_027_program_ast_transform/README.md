# Test 108: ProgramAST Full Transformation

## Status: DESIGN INTENT CAPTURED

**Parser**: ⏳ TODO - Already supports ProgramAST, needs event signature support
**Backend**: ⏳ TODO - Needs evaluate_comptime to handle ProgramAST returns

## What This Test Proves

This test captures **Level 3 metaprogramming** - full AST transformation for global compiler passes.

### The Signature

```koru
~event inject_logging {
    program_ast: *const ProgramAST,     // Full program AST
    allocator: std.mem.Allocator        // For allocations
}
| transformed { program_ast: *const ProgramAST }  // Modified AST
```

**Key difference from Level 2 (Item)**:
- Item transforms are **bounded** (one node at a time)
- ProgramAST transforms are **global** (entire program)

## The Three Levels Compared

| Level | Input | Output | Scope | Use Cases |
|-------|-------|--------|-------|-----------|
| **1: Source Capture** | `Source[T]` | (varies) | Text + scope | Templates, DSLs |
| **2: Item Transform** | `Item, ProgramAST` | `Item` | Single node | Bounded transforms |
| **3: AST Transform** | `ProgramAST` | `ProgramAST` | Whole program | Compiler passes |

### When to Use Each Level

**Level 1 (Source)**: Template expansion, DSL embedding
```koru
~event renderHTML { source: Source[HTML] }
```

**Level 2 (Item)**: Local transformations
```koru
~event optimize_call {
    source: Source[...],
    item: *const Item,
    program_ast: *const ProgramAST,
    allocator: std.mem.Allocator
}
| transformed { item: Item }
```

**Level 3 (ProgramAST)**: Global transformations
```koru
~event inject_logging {
    program_ast: *const ProgramAST,
    allocator: std.mem.Allocator
}
| transformed { program_ast: *const ProgramAST }
```

## Example: inject_logging Implementation

```zig
~proc inject_logging {
    const ast_functional = @import("ast_functional");

    // Transform all flows to add logging
    const transformed = try ast_functional.transformWhere(
        allocator,
        program_ast,
        isFlowPredicate,
        addLoggingTransform
    );

    return .{ .transformed = .{ .program_ast = transformed } };
}

fn isFlowPredicate(item: *const Item) bool {
    return item.* == .flow;
}

fn addLoggingTransform(allocator: std.mem.Allocator, item: *const Item) !Item {
    // Clone the flow
    const flow = item.flow;
    var modified_flow = try ast_functional.cloneFlow(allocator, &flow);

    // Insert logging invocation before first continuation
    // (Actual implementation would use ast_functional helpers)

    return .{ .flow = modified_flow };
}
```

## How It Fits in the Compiler Pipeline

ProgramAST transformations run as **explicit passes** in the coordination pipeline:

```koru
~compiler.coordinate.frontend =
    compiler.passes.evaluate_comptime(ctx: ctx)  // Level 2: Item transforms
    | continued c1 |> inject_logging(program_ast: c1.ctx.ast, allocator: allocator)  // Level 3: AST transform
      | transformed c2 |> continued { ctx: .{ .ast = c2.program_ast, ... } }
```

**NOT automatic** like Item transforms - you explicitly chain them in the pipeline!

## Use Cases

### 1. Instrumentation
```koru
~event inject_profiling { program_ast: *const ProgramAST }
| transformed { program_ast: *const ProgramAST }
```
- Insert timing/profiling code around every flow
- Add memory allocation tracking
- Inject error boundary wrappers

### 2. Whole-Program Optimization
```koru
~event inline_hot_paths { program_ast: *const ProgramAST }
| transformed { program_ast: *const ProgramAST }
```
- Analyze call graphs
- Inline frequently-called events
- Eliminate dead code

### 3. Architectural Transformations
```koru
~event convert_to_async { program_ast: *const ProgramAST }
| transformed { program_ast: *const ProgramAST }
```
- Convert synchronous flows to async
- Add cancellation support
- Transform blocking calls to non-blocking

### 4. Domain-Specific Passes
```koru
~event validate_actor_model { program_ast: *const ProgramAST }
| transformed { program_ast: *const ProgramAST }
```
- Enforce architectural constraints
- Validate patterns (actor model, state machines)
- Insert boilerplate

## Implementation TODOs

To make this test pass:

1. **evaluate_comptime changes**:
   - Detect events with ProgramAST parameters
   - Execute them as custom passes
   - Replace entire AST with returned ProgramAST
   - Update CompilerContext with new AST

2. **Coordination pipeline**:
   - Allow ProgramAST transforms in pipeline
   - Thread transformed AST through context
   - Support chaining multiple AST transforms

3. **ast_functional.zig**:
   - Already has the operations needed!
   - `transformWhere`, `filterItems`, `replaceAt`, etc.
   - Comptime procs just use these directly

## Why This Matters

This is **compiler extensibility** without forking the compiler:

```koru
// Want custom optimizations? Write a pass!
~event my_optimization { program_ast: *const ProgramAST }
| transformed { program_ast: *const ProgramAST }

// Want domain validation? Write a pass!
~event enforce_my_pattern { program_ast: *const ProgramAST }
| transformed { program_ast: *const ProgramAST }

// Chain them in your custom coordinator:
~compiler.coordinate =
    compiler.coordinate.default.frontend(...)
    | continued c1 |> my_optimization(...)
      | transformed c2 |> enforce_my_pattern(...)
        | transformed c3 |> compiler.coordinate.default.emission(...)
```

**Users can extend the compiler with typed, safe, composable passes!**

This is how frameworks will provide "magic" behavior - not through hidden mechanisms, but through **explicit, inspectable AST transformations**!
