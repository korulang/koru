# Koru

Koru is an event continuation/effect language with backends for Zig and JavaScript.

```koru
import std/io

tor greet { name: string } -> string

greet -> "Hello, " ++ name ++ "!"

greet (name: "World"): msg |> std/io:print.ln(msg)
```

The same program lives at `examples/greet/hello.k` (compile from the repo root —
**not** the root itself: `koruc` emits `build.zig` beside the input, and that
would overwrite this repo's compiler build):

```bash
zig build
./zig-out/bin/koruc examples/greet/hello.k
./examples/greet/a.out
```

Requires Zig 0.15.1 or later.

## Links

- [Website](https://korulang.org)
- [X](https://x.com/korulang)
- [Learn](https://korulang.org/learn)
- [Status](https://korulang.org/status) — or verify the snapshot locally: `./run_regression.sh --status`
- [Discord](https://discord.gg/tYWvdrda8h)
- [Examples](https://www.github.com/korulang/koru-examples)
- [Benchmarks](https://www.github.com/korulang/koru-benchmarks)

## License

MIT
