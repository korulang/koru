# Koru

Koru is an event continuation language that compiles to Zig. It provides a structured way to handle control flow through events, continuations, and taps.

```koru
~import "$std/io"

~event greet { name: []const u8 }
| greeting []const u8

~greet = greeting "Hello, " ++ name ++ "!"

~greet ("World")
| greeting msg |> std.io:print.ln(msg)
```

## Building

Requires Zig 0.15.1 or later.

```bash
zig build
```

## Links

- [Website](https://korulang.org)
- [Learn](https://korulang.org/learn)
- [Status](https://korulang.org/status)
- [Discord](https://discord.gg/tYWvdrda8h)

## License

MIT
