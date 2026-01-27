# Build Variants Test

Tests the `std.build:variants` event for conditional variant selection based on `--build` flag.

## Feature

`build:variants` allows defining different variant mappings for different build configurations:

```koru
~[release]std.build:variants {
    "compute": "fast",
    "blur": "gpu"
}

~[debug]std.build:variants {
    "compute": "naive",
    "blur": "cpu"
}
```

## How It Works

1. `InvocationMeta` captures flow annotations (`[release]`, `[debug]`)
2. The proc checks `CompilerEnv.hasFlag("build=release")` etc.
3. Only matching configurations populate the `VariantRegistry`
4. The emitter reads from `VariantRegistry` to select variants

## Compiling with Flags

```bash
# Use release variants
koruc main.kz --build=release

# Use debug variants
koruc main.kz --build=debug

# Use default variants (no flag)
koruc main.kz
```

## Registry API

The variant registry provides:

```zig
// In build.kz
pub fn getVariant(event_name: []const u8) ?[]const u8

// Usage in emitter
if (std.build.getVariant("compute")) |variant| {
    // Use variant instead of default
}
```

## Note

This is a compile-only test. The variant selection happens at compile time during the comptime phase, not at runtime.
