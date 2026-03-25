# Koru

Koru is an event continuation language that compiles to Zig. It provides a structured way to handle asynchronous control flow through events, continuations, and taps.

```koru
~event greet { name: []const u8 }
| greeting []const u8

~greet = greeting "Hello, " ++ name ++ "!"

~greet ("World")
| greeting msg |> print(msg)
```

This example doesn't compile yet. We're working on it.

## What Does Work

- Event declarations with typed branches
- Continuations chaining with `|>`
- Event taps for cross-cutting concerns
- Phantom types for compile-time resource tracking
- Liquid-style templating with zero overhead
- Metacircular compiler (parts of the compiler written in Koru)
- 500+ regression tests

## Building

Requires Zig 0.15.1 or later.

```bash
zig build
```

## Links

- [Website](https://korulang.org)
- [Learn Koru](https://korulang.org/learn)
- [Status](https://korulang.org/status)
- [Discord](https://discord.gg/tYWvdrda8h)

## License

MIT
