# Abstract Events and Implementation

## Feature Overview

Abstract events enable declaring event signatures that can be implemented elsewhere in the program. This provides dependency inversion without runtime overhead or OOP-style inheritance complexity.

## Syntax

### Declaring Abstract Events

```koru
~abstract event foo { input_fields... }
| branch_1 { fields... }
| branch_2 { fields... }
```

### Optional Default Implementation

```koru
~proc foo {
    // Default implementation logic
}
```

### Providing Implementation

```koru
~impl fully.qualified:foo =
    some_flow |> expression
    | branch |> continuation
```

## Semantics

### Declaration Site (Library)

```koru
// library.kz
~abstract event coordinate { ctx: CompilerContext }
| finished { ctx: CompilerContext }

~proc coordinate {
    // Optional default implementation
    // Provides baseline behavior that can be extended
}
```

### Implementation Site (User Code)

```koru
// user_code.kz
~import "$std/library"

~impl std.library:coordinate =
    std.library:coordinate(...)  // Delegates to default
    | finished f |> custom_logic()
```

**Within `~impl` scope:**
- Event name refers to the **default implementation** (delegation)
- Allows extending or wrapping default behavior
- If no default exists, calling it is a compile error

**Outside `~impl` scope:**
- Event name refers to the **impl version**
- Users always call the overridden implementation

## Compile-Time Guarantees

### Error: Abstract Event Not Implemented
```koru
~abstract event foo {}
// No ~impl provided
~foo()  // ERROR: Abstract event 'foo' not implemented
```

### Error: Multiple Implementations
```koru
~impl foo = ...
~impl foo = ...  // ERROR: Event 'foo' already implemented
```

### Error: Delegation to Non-Existent Default
```koru
~abstract event foo {}  // No ~proc foo
~impl foo = foo()  // ERROR: Cannot delegate to 'foo': no default implementation
```

### Error: Fully Qualified Name Required
```koru
~impl coordinate = ...  // ERROR: Implementation must use fully qualified name
~impl std.library:coordinate = ...  // OK
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
~abstract event compiler.coordinate {}
~proc compiler.coordinate {}  // Default
~impl std.compiler:compiler.coordinate = ...  // User override
```

### 2. Library Interfaces

```koru
// logger.kz
~abstract event log { message: []const u8 }
| done {}

~proc log {
    std.debug.print("{s}\n", .{message});  // Default: stderr
}

// user_code.kz
~impl logger:log =
    write_to_file(message)  // Custom: log to file
    | written |> .{ .done = .{} }
```

### 3. Test Mocking

```koru
// http_client.kz
~abstract event fetch { url: []const u8 }
| success { body: []const u8 }
| error { code: i32 }

// test.kz
~impl http_client:fetch =
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
- Explicit and searchable (`~impl` is greppable)
- Compile-time resolution (zero overhead)
- Single implementation enforced
- Delegation is explicit

### Comparison to Other Languages

**Rust:** `impl Trait for Type` + trait bounds + lifetimes → Complex

**Go:** `type Foo interface { ... }` + implicit implementation → Hidden

**Koru:** `~impl foo = ...` → Just a flow. Simple.

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

**Impl Declaration:**
```json
{
  "type": "impl_decl",
  "target_event": ["std", "library", "coordinate"],
  "implementation": {
    "type": "flow",
    ...
  }
}
```

### Resolution Strategy

1. Parse phase: Track `~abstract` events and `~impl` declarations
2. Import phase: Combine all ASTs, checking for duplicates
3. Canonicalize phase: Resolve fully qualified names
4. Validation phase:
   - Check all abstract events are implemented
   - Check no duplicate implementations
   - Check delegation targets exist
5. Emission phase: Replace abstract event calls with impl flows

### Edge Cases

**Delegation Chain:**
```koru
~impl foo = foo() | result |> foo()  // Calls default twice, NOT recursive
```

**Partial Delegation:**
```koru
~impl foo =
    foo(x: 1) | branch_a a |> custom_a()
    foo(x: 2) | branch_b b |> custom_b()
```

**No Delegation:**
```koru
~impl foo = completely_custom |> flow  // Don't use default at all
```

## Future Considerations

### Conditional Implementations

Not currently supported:
```koru
~[test] impl foo = mock_version()
~[prod] impl foo = real_version()
```

Could be added later if needed.

### Multiple Implementations with Feature Flags

Not currently supported:
```koru
~impl foo.windows = windows_version()
~impl foo.linux = linux_version()
```

Current design enforces single implementation. Conditional compilation may be better fit.
