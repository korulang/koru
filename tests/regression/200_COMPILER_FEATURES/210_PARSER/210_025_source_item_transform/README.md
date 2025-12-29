# Test 106: Source Parameter with Item Transformation

## Status: DESIGN INTENT CAPTURED

**Parser**: ⏳ TODO - Needs `Item` and `ProgramAST` type support
**Backend**: ⏳ TODO - Needs evaluate_comptime execution implementation

## What This Test Proves

This test captures the **design intent** of Koru's new metaprogramming API:

### The New Signature

```koru
~event simple_transform {
    source: Source[Text],              // Captured text + scope
    item: *const Item,                 // The AST node being transformed
    program_ast: *const ProgramAST,    // Full AST for context (read-only)
    allocator: std.mem.Allocator       // For allocations
}
| transformed { item: Item }           // Return the transformed node
```

### Why This Design?

**Bounded Transformations**: Each comptime event transforms ONLY its own AST node. This makes transformations:
- **Composable** - Multiple transforms don't interfere
- **Mechanical** - System can execute them automatically
- **Predictable** - Local reasoning about effects

**Three Levels of Access**:
1. `source` - The raw text and captured scope bindings
2. `item` - The specific node to transform
3. `program_ast` - Full AST for context queries

### What Happens When This Works?

```koru
~simple_transform [Text]{
    Hello from test 106!
}
```

The `evaluate_comptime` pass:
1. Detects this is a comptime invocation (has Source parameter)
2. Calls `simple_transform` proc at compile time
3. Passes: source, item (the flow node), program_ast, allocator
4. Receives back: transformed item
5. Replaces the original item in the AST

## Relationship to Other Tests

- **Test 105**: Proved parser captures scope in Source (✅ PASSING)
- **Test 106**: Proves Item transformation API (⏳ THIS TEST)
- **Test 107**: Proves depends_on ordering works
- **Test 108**: Proves full ProgramAST transformation works
- **Test 109**: Proves renderHTML works end-to-end with interpolation

## The Vision

This is **Level 2** of Koru's three-level metaprogramming system:

```
Level 1: Source Capture
  └─ Test 105 ✅

Level 2: Item Transformation  ← WE ARE HERE
  ├─ Test 106 (basic API)
  ├─ Test 107 (ordering)
  └─ Test 109 (renderHTML integration)

Level 3: AST Transformation
  └─ Test 108 (full AST manipulation)
```

## Implementation TODOs

To make this test pass, we need:

1. **Parser changes**:
   - Recognize `Item` as a field type
   - Recognize `*const Item` syntax
   - Recognize `ProgramAST` as a field type
   - Recognize `*const ProgramAST` syntax

2. **evaluate_comptime changes**:
   - Actually EXECUTE comptime procs (currently TODO at line 555 of compiler.kz)
   - Pass `item`, `program_ast`, `allocator` parameters
   - Receive transformed `item` result
   - Replace item in AST using ast_functional.zig

3. **AST support**:
   - Ensure Item type is accessible in backend
   - Ensure Program/ProgramAST alias works
   - Support const pointer parameters

## Why This Matters

This test captures the moment Koru becomes a **true metaprogramming language** with:
- Homoiconicity (AST as first-class data)
- Gradual levels (Source → Item → AST)
- Type safety (all transformations typed)
- Composability (bounded by default)
- Explicit ordering (via depends_on)

**This is the foundation of template metaprogramming, DSL embedding, and compiler extensions in Koru.**
