# Test 107: depends_on Ordering for Comptime Events

## Status: DESIGN INTENT CAPTURED

**Parser**: ⏳ TODO - Needs to recognize `depends_on` annotation with qualified names
**Backend**: ⏳ TODO - Needs dependency graph + topological sort in evaluate_comptime

## What This Test Proves

This test captures how **comptime event ordering** works using the existing `depends_on` mechanism from build steps, extended to work with fully qualified event names.

### The Annotation

```koru
~[depends_on("input:first_pass")]
~event second_pass {
    source: Source[Stage2],
    item: *const Item,
    program_ast: *const ProgramAST,
    allocator: std.mem.Allocator
}
| transformed { item: Item }
```

**Key insight**: Unlike build steps (which use local names like `"test"`), comptime events use **fully qualified names** like `"input:first_pass"` or `"std.compiler:preprocess"`.

Why? Because comptime events span **multiple modules** - they're not scoped to a single file like build steps.

## How It Works

### 1. Dependency Declaration

```koru
// No dependencies - executes first
~event first_pass { ... }

// Depends on first_pass - executes after
~[depends_on("input:first_pass")]
~event second_pass { ... }

// Depends on second_pass - executes last
~[depends_on("input:second_pass")]
~event third_pass { ... }
```

### 2. Dependency Graph Construction

The `evaluate_comptime` pass:
1. Scans all comptime events in the AST
2. Extracts `depends_on` annotations
3. Builds directed graph: `second_pass → first_pass`
4. Performs topological sort
5. Returns execution order: `[first_pass, second_pass, third_pass]`

### 3. Ordered Execution

Comptime events execute in dependency order:
```
first_pass  → transforms its items
second_pass → transforms its items (can rely on first_pass having run)
third_pass  → transforms its items (can rely on second_pass having run)
```

## Comparison to Build Steps

| Aspect | Build Steps | Comptime Events |
|--------|-------------|-----------------|
| **Scope** | Single build file | Entire program + imports |
| **Names** | Local: `"test"` | Qualified: `"input:first_pass"` |
| **When** | Build time (zig) | Compile time (koruc) |
| **Execution** | Shell commands | AST transformations |

**Same pattern, different domains!**

## Cross-Module Dependencies

The fully qualified naming enables dependencies across modules:

```koru
// In mylib.kz:
~[comptime]pub event validate_schema {
    source: Source[Schema],
    item: *const Item,
    program_ast: *const ProgramAST,
    allocator: std.mem.Allocator
}
| transformed { item: Item }

// In user code:
~[depends_on("mylib:validate_schema")]
~event generate_api {
    source: Source[OpenAPI],
    item: *const Item,
    program_ast: *const ProgramAST,
    allocator: std.mem.Allocator
}
| transformed { item: Item }
```

This enables **library-provided compile-time transformations** with explicit ordering!

## Implementation TODOs

To make this test pass:

1. **Parser changes**:
   - Recognize `depends_on("qualified:name")` annotation
   - Store annotation on event declarations
   - Handle module-qualified names

2. **evaluate_comptime changes**:
   - Build dependency graph from annotations
   - Implement topological sort
   - Execute comptime events in sorted order
   - Detect cycles and report errors

3. **Error handling**:
   - Detect missing dependencies
   - Detect circular dependencies
   - Give helpful error messages

## Why This Matters

**Composable metaprogramming** requires ordering:
- Schema validation before code generation
- Normalization before optimization
- Type inference before template expansion

By reusing `depends_on` from build steps, we get:
- ✅ Familiar syntax users already know
- ✅ Clear semantics (DAG + topological sort)
- ✅ Explicit dependencies (no hidden ordering)
- ✅ Cross-module composition

This is how **library ecosystems** will provide compile-time transformations that compose correctly!
