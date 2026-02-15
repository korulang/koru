# Koru Quick Reference

> Concise syntax reference - extracted from verified specs

For detailed explanations, see [SPEC.md](SPEC.md)

---

## File Structure

A `.kz` file is a **valid Zig file** with Koru extensions:

```koru
const std = @import("std");  // Regular Zig

~event greet { name: []const u8 }  // Koru construct
| greeting { message: []const u8 }

~proc greet {  // Koru proc
    return .{ .greeting = .{ .message = name } };
}
```

Lines starting with `~` are Koru constructs.

---

## Event Declaration

```koru
~[pub] event name { input_fields }
| branch_name { output_fields }
| branch_name { output_fields }
```

**Examples**:

```koru
// Public event with multiple branches
~pub event parse { input: []const u8 }
| success { ast: AST }
| error { message: []const u8, line: usize }

// Private void event (no output branches)
~event log { message: []const u8 }

// Event with namespaced name
~event file.read { path: []const u8 }
| success { content: []const u8 }
| error { reason: []const u8 }
```

---

## Proc Implementation

Procs are **pure Zig** code that returns branch constructors:

```koru
~proc event_name {
    // Input fields automatically in scope
    // Return branch constructor: .{ .branch_name = .{ fields } }
    return .{ .branch_name = .{ field: value } };
}
```

**Examples**:

```koru
~proc greet {
    const message = try std.fmt.allocPrint(
        allocator,
        "Hello, {s}!",
        .{name}  // 'name' from event input
    );
    return .{ .greeting = .{ .message = message } };
}

// Void event proc (no return needed)
~proc log {
    std.debug.print("{s}\n", .{message});
}
```

---

## Flow Invocation

```koru
~event_name(field: value, field2: value2)
| branch_name binding |> next_event()
| other_branch binding |> _  // Terminal
```

**Examples**:

```koru
// Simple flow
~greet(name: "Alice")
| greeting g |> print(message: g.message)
    | done |> _

// Handling errors
~parse(input: source)
| success s |> compile(ast: s.ast)
    | compiled |> _
| error e |> print_error(msg: e.message)
    | done |> _

// Multiple event calls
~greet(name: "Alice")
| greeting g |> process(g.message)

~greet(name: "Bob")
| greeting g |> process(g.message)
```

---

## Subflows

Subflows are compile-time event-to-branch bindings:

```koru
~event_name = implementation
```

**Forms**:

1. **Immediate** - Direct branch constructor:
```koru
~greet = greeting { message: name }
```

2. **Flow** - Call event and map output:
```koru
~process = double(value: input)
| result r |> final { output: r.doubled }
```

Subflows can also be chained (subflow calling another subflow). See `tests/regression/300_SUBFLOWS/` for more patterns.

---

## Taps (Event Observers)

Taps use `~tap()` with `->` to observe events **read-only**:

```koru
~tap(source -> destination)
| branch binding |> observer_action
```

**Examples**:

```koru
// Observe specific event outputs
~tap(file.read -> *)
| error e |> log.error(msg: e.reason)

// Observe all transitions to an event
~tap(* -> send_email)
| Transition t |> metrics.increment(counter: "emails_sent")

// Universal observer (see koru_std/ccp.kz for real implementation)
~tap(* -> *)
| Transition t |> emit_transition(
    source: t.source,
    branch: t.branch,
    destination: t.destination,
    duration_ns: t.duration_ns
)
```

**Key**: Taps are read-only, multiple taps execute independently.

---

## Imports

```koru
~import "path"
~import "$alias/path"
```

**Path Aliases**:
- `$std` - Standard library
- `$lib` - Project libraries
- `$root` - Project root

**Examples**:

```koru
~import "$std/io"
~import "$lib/database"
~import "utils/helpers"
```

---

## Types

Koru uses **Zig's type system**:

```koru
// Primitives
value: u32
flag: bool
ratio: f64

// Strings
name: []const u8

// Structs
config: struct { verbose: bool, max: u32 }

// Pointers
file: *File
items: []Item
```

### Phantom Types

Compile-time state tracking (see [Validation](tests/regression/400_VALIDATION/SPEC.md)):

```koru
~event open { path: []const u8 }
| opened { file: *File[fs:open] }  // Phantom state: fs:open
```

---

## Special Syntax

### Terminal Continuation

```koru
| branch |> _  // End of flow, no further processing
```

### Void Events

```koru
~event log { message: []const u8 }  // No output branches

~proc log {
    std.debug.print("{s}\n", .{message});
    // No return statement
}
```

### Annotations

```koru
~[benchmark] event compute { x: i32 }
| result { value: i32 }
```

See [Taps & Observers](tests/regression/500_TAPS_OBSERVERS/SPEC.md#annotations)

---

## Common Patterns

### Error Handling

```koru
~parse(input: source)
| success s |> compile(ast: s.ast)
    | compiled |> _
| error e |> log.error(msg: e.message)
    | done |> _
```

### Event Chaining

```koru
~read(path: "file.txt")
| success s |> parse(content: s.content)
| success p |> validate(ast: p.ast)
| valid v |> emit(ast: v.ast)
| emitted e |> write(path: "output.zig", content: e.code)
```

### Logging Pattern

```koru
// Tap into all events (universal observer)
~tap(* -> *)
| Transition t |> log.trace(
    source: t.source,
    branch: t.branch,
    dest: t.destination
)
```

---

## Execution Model

Events compile to:
1. **Namespace struct** containing handler
2. **Input struct** with event parameters
3. **Output union** with all branches
4. **Handler function** `handler(Input) Output`

Flow invocations are **inlined** at compile-time, creating zero-cost abstractions.

---

## Related Docs

- [SPEC.md](SPEC.md) - Full specification with test links
- [docs/architecture/COMPILER_ARCHITECTURE.md](docs/architecture/COMPILER_ARCHITECTURE.md) - Compiler internals
- [tests/regression/](tests/regression/) - Verified test examples

---

*All examples extracted from verified regression tests*
