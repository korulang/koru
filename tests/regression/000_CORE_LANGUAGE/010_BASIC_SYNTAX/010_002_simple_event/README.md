# Your First Event: ~event and ~proc

This test introduces the two fundamental Koru keywords: `~event` and `~proc`.

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

### The Proc

```koru
~proc hello {
    std.debug.print("Event executed\n", .{});
    return .{ .done = .{} };
}
```

A **proc** (procedure) is code that handles an event:
- `~proc hello` says "this handles the `hello` event"
- The body is regular Zig code
- `return .{ .done = .{} }` returns the `done` branch

## Why No Output?

This test compiles but produces no output. Why? Because nothing **triggers** the event. The event and proc exist, but no code calls them.

That's intentional—this test verifies that the syntax compiles. Later tests will show how to trigger events using **flows**.

## The Key Insight

Notice how Zig and Koru coexist:
- `std.debug.print(...)` is standard Zig
- `~event` and `~proc` are Koru extensions
- They integrate seamlessly

## What's Next

The next test explores event **shapes**—how events carry data in their inputs and outputs.
