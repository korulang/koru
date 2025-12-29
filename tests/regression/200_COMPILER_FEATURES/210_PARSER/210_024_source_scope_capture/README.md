# Test 105: Source Scope Capture - THE BREAKTHROUGH

## Status: Parser Complete ✅ | Backend TODO ⏳

## What We PROVED Today

**THIS IS THE PILLAR MOMENT!** 🚀

We successfully proved that Source parameters capture continuation bindings from lexical scope!

### The AST Shows It Works:

```json
"scope": {
    "bindings": [
        {
            "name": "u",
            "type": "unknown",
            "value_ref": "u"
        }
    ]
}
```

### What This Means

When you write:
```koru
~getUserData
| data u |> renderHTML [HTML]{
    <h1>${u.name}</h1>
    <p>Age: ${u.age}</p>
}
```

The parser:
1. ✅ **Recognizes the continuation pipeline Source block syntax**
2. ✅ **Captures the `u` binding from `| data u |>`**
3. ✅ **Stores it in `source.scope.bindings`** with full metadata
4. ✅ **Preserves the source text** for template processing
5. ✅ **Tags it with the phantom type** `HTML`

### What This Enables

This is THE FOUNDATION for all metaprogramming in Koru:

- **Template engines** that see variables in scope at compile time
- **DSL embedding** with lexical capture
- **Code generators** that inspect call-site context
- **Comptime string interpolation** with `${}`
- **ANY metaprogramming** that needs scope awareness

## Current Status

### ✅ Working (Parser/AST)
- Continuation pipeline Source block syntax: `| data u |> event [Type]{ }`
- Scope capture from continuations
- Binding metadata (name, type, value_ref)
- Source text preservation
- Phantom type annotations

### ⏳ TODO (Backend)
The backend currently tries to emit comptime flows as runtime code, causing compilation errors. The fix needed:

1. **Detect comptime flows with Source in pipelines** - The evaluate_comptime pass needs to recognize these
2. **Execute them during backend compilation** - Call the comptime proc and transform the flow
3. **Replace with runtime code** - The proc should generate runtime code to be emitted

This is the same pattern as module-level Source invocations (test 104), just needs extension to handle continuation pipelines.

## The Test Code

```koru
// Event that provides data
~event getUserData { }
| data { name: []const u8, age: i32 }

~proc getUserData {
    return .{ .data = .{ .name = "Alice", .age = 42 } };
}

// Comptime template processor
~event renderHTML { source: Source[HTML] }
| rendered { html: []const u8 }

~proc renderHTML {
    // THIS WORKS! source.scope.bindings[0] contains:
    // - name: "u"
    // - type: "unknown" (will be inferred)
    // - value_ref: "u"

    // Future: Parse ${} and generate interpolation code
    // For now: Just prove we can see the bindings
    const binding = source.scope.bindings[0];
    return .{ .rendered = .{ .html = binding.name } };
}

// THE PILLAR: This captures 'u' from the continuation!
~getUserData
| data u |> renderHTML [HTML]{
    <h1>${u.name}</h1>
    <p>Age: ${u.age}</p>
}
| rendered h |> std.io:println(text: h.html)
```

## Significance

**This is the moment Koru became a true metaprogramming language.**

With scope capture working, we can now build:
- Templates that compile to zero-cost runtime code
- DSLs that understand their context
- Macros with hygiene through lexical scope
- Code generators with full call-site information

The infrastructure is SOLID. The pillar stands. Now we build upward.

## Next Steps

1. **Extend evaluate_comptime pass** to handle continuation pipeline Source invocations
2. **Execute comptime procs** during backend compilation
3. **Transform the flow** to runtime code based on proc output
4. **Implement `${}` interpolation** in the renderHTML proc
5. **Generate runtime string concatenation** code from template

Then we'll have the first working end-to-end template engine with comptime metaprogramming! 🎉
