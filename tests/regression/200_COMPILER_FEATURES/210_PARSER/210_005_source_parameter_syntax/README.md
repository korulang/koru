# Test 055: Source Parameter Syntax

## Purpose

Verify that the parser correctly recognizes and marks `Source` as a special parameter type in event declarations.

## Test Code

```koru
~event compile { code: Source }
| compiled { result: []const u8 }

~event macro_expand { template: Source }
| expanded { code: []const u8 }
```

## What This Tests

1. **Parser recognizes `Source` keyword** in field type position
2. **AST marks Source parameters** with `is_source: true` flag
3. **Type information preserved** in TypeRegistry

## Current Status

**PASSING** (with memory leak warning)

### What Works
- ✅ Parser correctly recognizes `Source` type
- ✅ AST includes `is_source: true` marker
- ✅ TypeRegistry contains the event with correct signature
- ✅ Code generation produces compilable output
- ✅ Backend execution succeeds

### What Needs Fixing
- ⚠️  Memory leak in compiler (not in generated code)

### Test Output

```
✓ Compiled input.kz → backend.zig
✓ Generated backend_output_emitted.zig (287 bytes)
❌ PASS but memory leak detected (frontend)
```

## Verification Commands

```bash
# Get AST JSON to verify parsing
koruc --ast-json input.kz 2>&1 | grep -A 999999 '^{' | jq '.items[0].event_decl.input.fields[0]'

# Expected output:
{
  "name": "code",
  "type": "Source",
  "is_flow_ast": false,
  "is_source": true,
  "is_file": false,
  "is_embed_file": false
}
```

## Comparison with FlowAST (Test 054)

| Aspect | Source (Test 055) | FlowAST (Test 054) |
|--------|-------------------|-------------------|
| Parser | ✅ Works | ✅ Works |
| AST Marking | ✅ is_source: true | ✅ is_flow_ast: true |
| Code Generation | ✅ Works | ❌ Generates wrong type |
| Backend Execution | ✅ Works | ❌ Type error |
| Memory Leaks | ⚠️  Leak in compiler | ❌ Leak in compiler |

**Key Insight:** Source parameters work end-to-end, FlowAST parameters have codegen issues.

## Source vs FlowAST Design

### Source
- Raw source code as string
- Runtime type: `[]const u8` (string slice)
- Used for: Macros, code generation, DSL compilation
- Easy to represent at runtime

### FlowAST
- Structured flow representation
- Runtime type: ??? (needs design decision)
  - Option A: `*const ast.FlowAST` (pointer to AST)
  - Option B: Compiled bytecode for flow execution
  - Option C: Function pointer with captured context
- Used for: Threading, metaprogramming, compiler passes
- Complex runtime representation

## Next Steps

1. Fix memory leak in compiler
2. Use this test as reference for fixing FlowAST codegen
3. Design FlowAST runtime representation

---

**Test Type:** Parser validation
**Status:** Parsing works ✅, Codegen works ✅, Memory leak ⚠️
