# The Two-AST Model for Program Transformations

## THIS FILE IS **WRONG** AND SHOULD BE UPDATED OR REMOVED

This is correct:

- FlowAST is a type that parses part of the program and delivers it to a proc
- ProgramAST is a pointer to PROGRAM_AST which is an immutable AST serialized directly into the compiler backend after parsing
- During compile-time, you can manipulate these different ASTs with a functional, immutable interface

BOTH of these can be manipulated using `ast_functional.zig`.

Always check REGRESSION TESTS for UPDATED DOCUMENTATION AND EXAMPLES




---

# BELOW IS HISTORICAL

**Status:** Discovered through experimentation! 🎉

## The Discovery

While implementing FlowAST metaprogramming, we stumbled upon an elegant solution to a hard problem: **How do you chain transformations when the AST is changing?**

The answer emerged organically from trying things and seeing what worked.

## The Model

When a comptime handler receives both `FlowAST` and `ProgramAST` parameters:

### 1. FlowAST = Immutable Pointer to ORIGINAL AST
```
Points to: Original serialized AST (what user wrote in source file)
Properties:
  - Never changes, even after transformations
  - Always valid pointer (points to static data)
  - Shows ORIGINAL user intent
  - Used for INSPECTION ("what did they write?")
```

### 2. ProgramAST = Mutable Current Transformed State
```
Points to: Current AST state (after previous handlers)
Properties:
  - Changes with each transformation
  - May have nodes added/removed/modified
  - Shows CURRENT reality
  - Used for TRANSFORMATION (building new AST)
```

### 3. Handler's Job = Bridge Intent → Reality
```zig
~proc optimize {
    comptime {
        // FlowAST: What user originally wrote
        const original = e.flow;

        // ProgramAST: Current state (may be transformed)
        const current = e.ast;

        // PATTERN:
        // 1. Inspect original to understand intent
        // 2. Search current to see if nodes still exist
        // 3. Transform based on BOTH contexts

        if (findInAST(current, original)) {
            // Found! Transform it
            return .{ .optimized = .{ .ast = transformAST(current) } };
        } else {
            // Not found - already removed by previous pass
            // This is NORMAL and EXPECTED!
            return .{ .optimized = .{ .ast = current } };
        }
    }
}
```

## Why This Works

### No Dangling Pointers
- FlowAST points to immutable serialized data
- That data never changes or gets freed
- Always safe to dereference

### Chained Transformations
- Handler 1: Removes node X, returns AST1
- Handler 2: Receives FlowAST→X (original) + AST1 (current)
- Handler 2: Searches for X, doesn't find it
- Handler 2: Gracefully handles "not found" case
- No crashes, no invalid memory access!

### Context for Decisions
- Original intent: "What did the user want?"
- Current reality: "What's actually in the program now?"
- Handler can make intelligent decisions based on BOTH

## Example: Chained Optimization

```koru
// User writes:
~optimize_pass1 { ~expensive() | r |> _ }
~optimize_pass2 { ~expensive() | r |> _ }

// Handler 1: Dead code elimination
~proc optimize_pass1 {
    // e.flow points to original expensive() call
    // e.ast is the whole program

    if (isDeadCode(e.flow, e.ast)) {
        // Remove expensive() from AST
        return removeFlow(e.ast, e.flow);
    }
}

// Handler 2: Inlining optimizer
~proc optimize_pass2 {
    // e.flow STILL points to original expensive() call
    // e.ast has expensive() ALREADY REMOVED by pass1!

    if (findInAST(e.ast, e.flow)) {
        // Found it! Inline it
        return inlineFlow(e.ast, e.flow);
    } else {
        // Not found - already optimized away
        // Return current AST unchanged
        return .{ .inlined = .{ .ast = e.ast } };
    }
}
```

## Common Patterns

### Pattern 1: Inspect Original, Transform Current
```zig
const user_intent = analyzeFlowAST(e.flow);
const optimized = optimizeBasedOnIntent(e.ast, user_intent);
return .{ .transformed = .{ .ast = optimized } };
```

### Pattern 2: Search for Original in Current
```zig
if (findFlowInAST(e.ast, e.flow)) {
    return transformFlow(e.ast, e.flow);
} else {
    return .{ .unchanged = .{ .ast = e.ast } };
}
```

### Pattern 3: Global Transform Based on Local Context
```zig
// FlowAST shows local invocation
// But we transform the WHOLE program
const patterns = extractPatterns(e.flow);
const globally_optimized = applyGlobally(e.ast, patterns);
return .{ .optimized = .{ .ast = globally_optimized } };
```

## Implementation Status

### ✅ What Works
- FlowAST and ProgramAST parameters
- Handler generation with both parameters
- Comptime invocations removed from final output
- Test 807: Two-AST model documentation
- Test 808: Chained transformations

### ⏳ What's Next
- AST helper functions (findFlowInAST, etc.)
- Real transformation examples
- Source parameter testing
- Complete test suite (801-810)

## How We Discovered This

We didn't plan this! It emerged from:
1. Trying to make FlowAST work
2. Realizing pointers needed to stay valid
3. Discovering serialized AST is immutable
4. Testing chained transformations
5. Observing that "not found" is normal

**Sometimes the best designs come from fumbling around and seeing what works!** 🚀

## Acknowledgments

This design was discovered collaboratively through experimentation. Neither of us knew this would work - we just tried things until it did!

> "Perhaps it is Jesus helping us out!" - larsde

Indeed. Or just the joy of exploration and collaborative problem-solving. ✨