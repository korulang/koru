# Build Flag Check Test

Tests that `CompilerEnv.hasFlag()` can be used with `InvocationMeta` annotations to conditionally activate configurations based on the `--build` flag.

## How It Works

1. `InvocationMeta` captures flow annotations (`[release]`, `[debug]`)
2. Comptime proc checks `Root.CompilerEnv.hasFlag("build=release")` etc.
3. Only matching configurations are activated

## Usage Pattern

```koru
~[comptime]pub event config { meta: InvocationMeta }
| activated { name: []const u8 }
| skipped {}

~proc config {
    for (meta.annotations) |ann| {
        if (std.mem.eql(u8, ann, "release")) {
            if (Root.CompilerEnv.hasFlag("build=release")) {
                return .{ .activated = .{ .name = "release" } };
            }
        }
    }
    return .{ .skipped = .{} };
}

~[release]config()  // Only activates with --build=release
~[debug]config()    // Only activates with --build=debug
```

## Running with Flags

```bash
# Compile with release config
koruc input.kz --build=release

# Compile with debug config
koruc input.kz --build=debug
```

## Note

This is a compile-only test. The comptime flows execute during backend compilation (Pass 2), so their effects happen at compile time, not runtime. The `println` calls in the continuations would execute during compilation, not when running the final program.

For the `build:variants` feature, this pattern would populate a variant registry at compile time, which the emitter then reads when generating code.
