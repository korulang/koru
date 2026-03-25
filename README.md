# Koru

Koru is an event continuation language that compiles to Zig. It provides a structured way to handle asynchronous control flow through events, continuations, and taps.

## Quick Example

```koru
~event greet { name: []const u8 }
| greeting []const u8

~greet = greeting "Hello, " ++ e.name ++ "!"

~greet ("World")
| greeting msg |> print(msg)
```

## Key Concepts

- **Events** define typed messages with named branches for different outcomes
- **Continuations** chain event handlers using `|>` syntax
- **Taps** intercept and transform events across modules with `~tap(source -> dest)`
- **Procs** implement the actual logic for events

## Building

Koru requires Zig 0.15.1 or later.

```bash
zig build
```

This produces the `koruc` compiler in `zig-out/bin/`.

## Usage

```bash
# Compile a Koru file to Zig
./zig-out/bin/koruc myfile.kz

# Initialize a new project
./zig-out/bin/koruc init myproject
```

## Project Structure

```
src/           # Compiler source (Zig)
koru_std/      # Standard library (Koru + Zig)
tests/         # Test suite
docs/          # Documentation
```

## Status

Koru is in active development. See the [changelog](CHANGELOG.md) for recent updates and the [status page](https://korulang.org/status) for current test coverage.

## Links

- [Website](https://korulang.org)
- [Learn Koru](https://korulang.org/learn)
- [Discord](https://discord.gg/tYWvdrda8h)

## License

MIT
