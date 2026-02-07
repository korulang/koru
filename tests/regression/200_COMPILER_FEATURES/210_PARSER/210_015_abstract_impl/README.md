# Abstract Events and Cross-Module Overrides

## Feature Overview

Abstract events enable declaring event signatures that can be overridden elsewhere in the program. This provides dependency inversion without runtime overhead or OOP-style inheritance complexity.

## Syntax

### Declaring Abstract Events

```koru
~[abstract] event foo { input_fields... }
| branch_1 { fields... }
| branch_2 { fields... }
```

### Optional Default Implementation

```koru
~proc foo {
    // Default implementation logic
}
```

### Providing an Override

The colon in the event path (`:`) signals a cross-module override:

```koru
~fully.qualified:foo =
    some_flow |> expression
    | branch |> continuation
```

There is no special keyword — the `:` in the path is what makes it an implementation override.

## Semantics

### Declaration Site (Library)

```koru
// library.kz
~[abstract] event coordinate { ctx: CompilerContext }
| finished { ctx: CompilerContext }

~proc coordinate {
    // Optional default implementation
    // Provides baseline behavior that can be extended
}
```

### Override Site (User Code)

```koru
// user_code.kz
~import "$std/library"

~std.library:coordinate =
    std.library:coordinate(...)  // Delegates to default
    | finished f |> custom_logic()
```

**Within override scope:**
- Event name refers to the **default implementation** (delegation)
- Allows extending or wrapping default behavior
- If no default exists, calling it is a compile error

**Outside override scope:**
- Event name refers to the **overridden version**
- Users always call the overridden implementation

## Compile-Time Guarantees

### Error: Abstract Event Not Implemented
```koru
~[abstract] event foo {}
// No override provided
~foo()  // ERROR: Abstract event 'foo' not implemented
```

### Error: Multiple Implementations
```koru
~mod:foo = ...
~mod:foo = ...  // ERROR: Event 'foo' already implemented
```

### Error: Delegation to Non-Existent Default
```koru
~[abstract] event foo {}  // No ~proc foo
~mod:foo = foo()  // ERROR: Cannot delegate to 'foo': no default implementation
```

### Error: Fully Qualified Name Required
```koru
~coordinate = ...  // ERROR: Implementation must use fully qualified name
~std.library:coordinate = ...  // OK (colon indicates cross-module override)
```

## Use Cases

### 1. Customizable Compiler Coordination

**Before (special-case hack):**
```koru
// Compiler has special handling for coordinate vs coordinate.default
~event compiler.coordinate {}
~proc compiler.coordinate.default {}  // Manual naming
```

**After (clean abstraction):**
```koru
~[abstract] event compiler.coordinate {}
~proc compiler.coordinate {}  // Default
~std.compiler:compiler.coordinate = ...  // User override
```

### 2. Library Interfaces

```koru
// logger.kz
~[abstract] event log { message: []const u8 }
| done {}

~proc log {
    std.debug.print("{s}\n", .{message});  // Default: stderr
}

// user_code.kz
~logger:log =
    write_to_file(message)  // Custom: log to file
    | written |> .{ .done = .{} }
```

### 3. Test Mocking

```koru
// http_client.kz
~[abstract] event fetch { url: []const u8 }
| success { body: []const u8 }
| error { code: i32 }

// test.kz
~http_client:fetch =
    .{ .success = .{ .body = "mock response" } }  // No network call
```

## Design Principles

### Why This is Better Than OOP Abstract

**OOP Problems:**
- Inheritance hierarchies (fragile base class)
- Hidden overrides (which method runs?)
- Virtual dispatch (runtime overhead)
- Multiple inheritance diamonds
- Hard to find implementations

**Koru Solutions:**
- Flat, not hierarchical (no inheritance tree)
- Explicit and searchable (`:` in event path is greppable)
- Compile-time resolution (zero overhead)
- Single implementation enforced
- Delegation is explicit

### Comparison to Other Languages

**Rust:** `impl Trait for Type` + trait bounds + lifetimes → Complex

**Go:** `type Foo interface { ... }` + implicit implementation → Hidden

**Koru:** `~mod:foo = ...` → Just a flow. Simple.

## Implementation Notes

### AST Representation

**Abstract Event Declaration:**
```json
{
  "type": "event_decl",
  "is_abstract": true,
  "name": "coordinate",
  "input": { ... },
  "branches": [ ... ]
}
```

**Override (SubflowImpl with is_impl=true):**
```json
{
  "type": "subflow_impl",
  "event_path": ["std", "library", "coordinate"],
  "is_impl": true,
  "body": {
    "type": "flow",
    ...
  }
}
```

### Resolution Strategy

1. Parse phase: Track abstract events and cross-module overrides
2. Import phase: Combine all ASTs, checking for duplicates
3. Canonicalize phase: Resolve fully qualified names
4. Validation phase:
   - Check all abstract events are implemented
   - Check no duplicate implementations
   - Check delegation targets exist
5. Emission phase: Replace abstract event calls with override flows

### Edge Cases

**Delegation Chain:**
```koru
~mod:foo = foo() | result |> foo()  // Calls default twice, NOT recursive
```

**Partial Delegation:**
```koru
~mod:foo =
    foo(x: 1) | branch_a a |> custom_a()
    foo(x: 2) | branch_b b |> custom_b()
```

**No Delegation:**
```koru
~mod:foo = completely_custom |> flow  // Don't use default at all
```

## Future Considerations

### Conditional Implementations

Not currently supported:
```koru
~[test] mod:foo = mock_version()
~[prod] mod:foo = real_version()
```

Could be added later if needed.

### Multiple Implementations with Feature Flags

Not currently supported:
```koru
~mod:foo.windows = windows_version()
~mod:foo.linux = linux_version()
```

Current design enforces single implementation. Conditional compilation may be better fit.
