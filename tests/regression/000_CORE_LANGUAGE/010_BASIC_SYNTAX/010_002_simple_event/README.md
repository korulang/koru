# Event Interface and Host Proc Boundary

This test introduces `~event` and the host implementation boundary, `~proc`.
It is intentionally minimal: it proves an event can be implemented by Zig code,
but it is not the preferred pattern for ordinary Koru logic. When behavior can
be expressed as event composition, prefer a subflow implementation:
`~event_name = ...`.

## The Code

```koru
~event hello {}
| done {}

~proc hello {
    std.debug.print("Event executed\n", .{});
    return .{ .done = .{} };
}
```

## Breaking It Down

### The Event Declaration

```koru
~event hello {}
| done {}
```

This declares an **event** named `hello`:
- `{}` after the name is the **input shape** (empty here—this event takes no parameters)
- `| done {}` declares a **branch** called `done` (also with empty shape)

Think of an event as a request with possible responses. Here, `hello` is a request that can respond with `done`.

### The Host Proc

```koru
~proc hello {
    std.debug.print("Event executed\n", .{});
    return .{ .done = .{} };
}
```

A **proc** (procedure) is host/Zig code that handles an event:
- `~proc hello` says "this handles the `hello` event"
- The body is regular Zig code, not Koru flow syntax
- `return .{ .done = .{} }` returns the `done` branch

Use this when the implementation must touch host/Zig APIs, target-specific
code, or low-level behavior. For normal event composition, use a subflow
implementation (`~hello = ...`) instead.

## Why No Output?

This test compiles but produces no output. Why? Because nothing **triggers** the event. The event and proc exist, but no code calls them.

That's intentional—this test verifies that the syntax compiles. Later tests will show how to trigger events using **flows**.

## The Key Insight

Notice how Zig and Koru coexist:
- `std.debug.print(...)` is standard Zig
- `~event` and `~proc` are Koru extensions
- They integrate seamlessly

That coexistence is a boundary, not an invitation to put flow-shaped Koru logic
inside a proc.

## What's Next

The next test explores event **shapes**—how events carry data in their inputs and outputs.
