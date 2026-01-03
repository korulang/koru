# Koru Language Syntax Reference

> Auto-generated from 260 passing regression tests
> Last updated: 2026-01-03T08:41:36.899Z
>
> This file is designed for LLM context injection. Keep it concise.

# Koru Language Reference (Zig Superset)

## THE MOST IMPORTANT RULE

**`~` is ONLY for top-level declarations and flow starts. NEVER use `~` inside a flow.**

```koru
// CORRECT:
~proc main {}
| done |>
    some_event(x: 1)        // No ~ inside flow!
    | ok r |>
        another(y: r.val)   // No ~ here either!

// WRONG:
~proc main {}
| done |>
    ~some_event(x: 1)       // WRONG! No ~ inside flows!
    | ok r |>
        ~another(y: r.val)  // WRONG!
```

The `~` prefix is used for:
- `~event` - declare an event
- `~proc` - declare a proc
- `~import` - import a module
- `~some_event()` - START a top-level flow

Inside continuations (`|>`), just use the bare event name.

## Event Declarations
Events define the "shape" of transitions. They can have input parameters and multiple output branches.

```koru
// Basic event
~event <name> {}

// Event with input and branches
~event <name> { <field>: <Type>, ... }
| <branch1> { <field>: <Type>, ... }
| <branch2> {} // Empty payload
| ?<optional_branch> { ... }

// Examples
~event greet { name: []const u8 }
| success { msg: []const u8 }
| error { code: i32 }

~event tick {} // Void event (no branches)
```

## Proc Declarations (Implementation)
Procs implement the logic for an event. They use Zig syntax for the body.

```koru
// Standard Proc
~proc <event_name> {
    // Zig code
    return .{ .<branch> = .{ .<field> = <value> } };
}

// Inline Flow Proc (Implicit Return)
~proc <name> = <flow_expression>

// Examples
~proc greet {
    if (std.mem.eql(u8, name, "admin")) return .{ .error = .{ .code = 403 } };
    return .{ .success = .{ .msg = "Hello" } };
}

~proc calculate = add(x: a, y: b)
| done r |> result { val: r.result }
```

## Flows and Continuations
Flows invoke events and handle their branches using pipelines (`|>`).

```koru
// Top-level invocation
~<event>(<args>)
| <branch> <binding> |> <next_step>
| <branch> |> _ // Discard/Terminal

// Chained continuations
~get_data()
| success d |> process(val: d.data)
    | ok r |> save(result: r)
        | done |> _
| error e |> log(msg: e.msg)

// Void event chaining
~step_one() |> step_two() |> step_three()
```

## Subflows
Terse event implementations that map inputs directly to outputs or chain other events.

```koru
// Immediate mapping
~<event> = <branch> { <out_field>: <in_field>, ... }

// Chained subflow
~<event> = <other_event>(<args>)
| <branch> <bind> |> <target_branch> { <field>: <bind>.<field> }

// Examples
~double = result { doubled: value * 2 }
~process = validate(val: input) | ok |> success { input }
```

## Labels and Jumps (Loops)
Used for recursion and looping within a flow. Labels are flow-scoped.

```koru
// Define label with #, jump with @
~#<label> <event>(<args>)
| <branch> <bind> |> @<label>(<updated_args>)
| <exit_branch> |> _

// Example
~#loop count(i: 0)
| next n |> @loop(i: n.value)
| done |> _
```

## Imports and Namespaces
Koru uses a strict alias-based import system.

```koru
// Syntax
~import "$<alias>/<path>"

// Usage
~<alias>.<module>:<event>(<args>)

// Examples
~import "$std/io"
~import "$app/lib/net"

~std.io:println(text: "Hello")
~app.lib.net.tcp:connect(port: 80)
```

## Annotations
Metadata for the compiler, placed before declarations or calls.

```koru
// Inline
~[<attr1>|<attr2>] <construct>

// Vertical (Bullet)
~[
-comptime
-pure
] proc <name> { ... }

// Common Annotations
~[pub]          // Export event/type
~[comptime]     // Execute at compile time
~[pure]         // No side effects
~[keyword]      // Allow unqualified usage
~[norun]        // Skip codegen
```

## Phantom Types
Track resource states at compile time.

```koru
// Syntax: <Type>[<state>]
// ! suffix denotes a cleanup obligation

~event open { p: []u8 } | opened { file: *File[opened!] }
~event close { file: *File[!opened] } | closed {}

// Usage
~open(p: "log.txt")
| opened f |> close(file: f.file) // Obligation satisfied
```

## Metaprogramming (Source & Expression)
`Source` captures blocks of text; `Expression` captures raw Zig code strings.

```koru
// Source Block Syntax
~<event> [<Type>]{
    <content>
}

// Expression Syntax (Implicitly mapped to 'expr' field)
~if(<condition_expr>)
| then |> ...

// Example: Template expansion
~std.template:define(name: "log") { std.debug.print("${msg}\n", .{}); }
~[expand]event log { msg: Expression }
~log("Hello") // Inlines Zig print
```

## Common Gotchas
1.  **Indentation**: Continuations (`|`) must start on a new line with proper indentation.
2.  **Parentheses**: `~event()` requires `()` if no source block is present. `~event [Type]{}` does not.
3.  **Shadowing**: Koru forbids duplicate binding names in the same flow scope.
4.  **Imports**: Must start with a `$` alias (e.g., `$std`, `$app`). Relative paths like `../` are forbidden.
5.  **Zig Keywords**: Branch names that are Zig keywords (like `error`) are automatically escaped as `.@"error"`.