# Koru

Koru is an event continuation/effect language with backends for Zig and JavaScript. It is aspirational and immature.

```koru
import std/io

event greet { name: []const u8 } -> []const u8

greet -> "Hello, " ++ name ++ "!"

greet ("World"): msg |> std/io:print.ln(msg)
```

## Building

Requires Zig 0.15.1 or later.

```bash
zig build
```

## Links

- [Website](https://korulang.org)
- [X](https://x.com/korulang)
- [Learn](https://korulang.org/learn)
- [Status](https://korulang.org/status)
- [Discord](https://discord.gg/tYWvdrda8h)

## License

MIT
