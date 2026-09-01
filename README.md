# Koru

Koru is an event continuation/effect language with backends for Zig and JavaScript.

```koru
import std/io

tor greet { name: string } -> string

greet -> "Hello, " ++ name ++ "!"

greet (name: "World"): msg |> std/io:print.ln(msg)
```

Save as `hello.k` and compile from this directory (needs the repo's `koru.json` for `std/`):

```bash
zig build
./zig-out/bin/koruc hello.k
```

Requires Zig 0.15.1 or later.

## Links

- [Website](https://korulang.org)
- [X](https://x.com/korulang)
- [Learn](https://korulang.org/learn)
- [Status](https://korulang.org/status)
- [Discord](https://discord.gg/tYWvdrda8h)
- [Examples](https://www.github.com/korulang/koru-examples)
- [Benchmarks](https://www.github.com/korulang/koru-benchmarks)

## License

MIT
