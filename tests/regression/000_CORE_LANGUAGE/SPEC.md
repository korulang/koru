# Core Language Specification

> The fundamentals - events, procs, flows, and types.

📚 **[Back to Main Spec Index](../../../SPEC.md)**

**Last Updated**: 2025-10-05
**Test Range**: 101-105

---

## File Structure

A `.kz` file is a **valid Zig file** with Koru extensions:
- Zig code is written normally
- Lines starting with `~` enter Koru parsing mode for that construct
- The compiler processes Koru constructs and generates Zig code

**Example**:
```koru
const std = @import("std");  // Regular Zig

~event greet { name: []const u8 }  // Koru construct
| greeting { message: []const u8 }

~proc greet {  // Koru proc
    return .{ .greeting = .{ .message = name } };
}
```

See: [101_hello_world](../101_hello_world/)

---

## Lexical Elements

### The Tilde Marker (`~`)

The `~` marks Koru constructs at the top level:
- `~event` - Event declaration
- `~proc` - Proc implementation
- `~import` - Module import
- `~TAP` - Event tap attachment

**Inside flows**, no `~` is needed:
```koru
~greet(name: "World")      // Top-level: needs ~
| greeting g |> process()  // Inside flow: no ~ needed
```

### Identifiers

Event names can use **dots** for namespacing:
```koru
~event file.read { path: []const u8 }
~event user.auth.login { username: []const u8, password: []const u8 }
```

Dots create nested structs in generated code:
```zig
pub const file = struct {
    pub const read = struct { /* ... */ };
};
```

### Indentation

Koru uses **indentation** to determine flow boundaries:
- Each event invocation must handle all its branches
- Parser tracks branch coverage
- Indentation makes the code unambiguous (continuation branches can be created at comptime)

**Why**: Event branches can be generated at compile-time, so the parser can't statically know all possible continuations.

---

## Event Declaration

### Basic Syntax

```koru
~[annotations]pub event name { input_fields }
| branch_name { output_fields }
| branch_name { output_fields }
```

**Private events** (omit `pub`):
```koru
~event name { input_fields }
| branch_name { output_fields }
```

**Annotations** are always optional (see [Taps & Observers](../500_TAPS_OBSERVERS/SPEC.md#annotations)).

### Branch Order

Branch order is **semantically significant** - list hot paths first for optimization.

The compiler may use branch order to:
- Generate more efficient dispatch code
- Optimize for common cases
- Improve branch prediction

### Void Events

Events can have **no output branches** (void events):
```koru
~event log { message: []const u8 }

~proc log {
    std.debug.print("{s}\n", .{message});
    // No return - void event
}
```

See: [105_void_event](../105_void_event/)

### Field Types

Input and output fields use **Zig types**:
```koru
~event compute {
    x: i32,
    y: i32,
    options: struct { verbose: bool }
}
| result { sum: i32 }
```

---

## Proc Implementation

### Zig Implementation

Procs are implemented in **pure Zig**:
```koru
~proc greet {
    // 'name' is automatically in scope from event input
    const message = try std.fmt.allocPrint(
        allocator,
        "Hello, {s}!",
        .{name}
    );
    return .{ .greeting = .{ .message = message } };
}
```

**Implicit bindings**:
- All event input fields are in scope
- Return value must be a branch constructor (`.{ .branch_name = .{ fields } }`)
- Void events don't need a return statement

See: [102_simple_event](../102_simple_event/)

### Variable Scope

Input fields are automatically available:
```koru
~event process { value: u32, config: Config }
| success { result: u32 }

~proc process {
    // 'value' and 'config' are in scope
    const result = value * config.multiplier;
    return .{ .success = .{ .result = result } };
}
```

---

## Flow Invocation

### Basic Invocation

```koru
~event_name(field: value, field2: value2)
| branch_name binding |> next_step()
| other_branch |> _  // Terminal
```

**Continuations** handle each branch:
- `binding` captures the branch payload
- `|> next_step()` pipes to next event
- `|> _` terminates (no further processing)

See: [103_simple_flow](../103_simple_flow/)

### Multiple Flows

Multiple flows can invoke the same event:
```koru
~greet(name: "Alice")
| greeting g |> process(g.message)

~greet(name: "Bob")
| greeting g |> process(g.message)
```

See: [104_multiple_flows](../104_multiple_flows/)

---

## Type System

### Base Types

Koru uses **Zig's type system**:
- Primitives: `u32`, `i32`, `f64`, `bool`, etc.
- Strings: `[]const u8`
- Structs: `struct { field: Type }`
- Unions: `union(enum) { variant: Type }`
- Pointers: `*Type`, `[]Type`

### Branch Payloads

Branch outputs are **Zig structs**:
```koru
~event parse { input: []const u8 }
| success { ast: AST }
| error { message: []const u8, line: usize }
```

Generated:
```zig
pub const Output = union(enum) {
    success: struct { ast: AST },
    error: struct { message: []const u8, line: usize },
};
```

### Phantom Types

Koru extends Zig with **phantom type states** for compile-time state tracking:
```koru
~event open { path: []const u8 }
| opened { file: *File[fs:open] }  // Phantom state: fs:open
```

See: [Validation - Phantom Types](../400_VALIDATION/SPEC.md#phantom-types)

---

## Execution Model

### Event Dispatch

Events compile to **struct namespaces** with a `handler` function:
```zig
pub const greet = struct {
    pub const Input = struct { name: []const u8 };
    pub const Output = union(enum) {
        greeting: struct { message: []const u8 }
    };
    pub fn handler(e: Input) Output {
        // Proc implementation
    }
};
```

### Flow Compilation

Flows compile to **Zig functions**:
```zig
pub fn flow0() void {
    const result = greet.handler(.{ .name = "World" });
    switch (result) {
        .greeting => |g| {
            // Continuation code
        },
    }
}
```

### Main Entry

Generated `main()` calls all top-level flows:
```zig
pub fn main() void {
    main_module.flow0();
    main_module.flow1();
    // ...
}
```

---

## Verified By Tests

- [101_hello_world](../101_hello_world/) - Basic compilation
- [102_simple_event](../102_simple_event/) - Event + proc
- [103_simple_flow](../103_simple_flow/) - Flow invocation
- [104_multiple_flows](../104_multiple_flows/) - Multiple flows
- [105_void_event](../105_void_event/) - Void events

---

## Related Specifications

- [Control Flow](../100_CONTROL_FLOW/SPEC.md) - Branches, labels, continuations
- [Validation](../400_VALIDATION/SPEC.md) - Type checking, phantom types
- [Optimizations](../910_OPTIMIZATIONS/SPEC.md) - Optional branches
