# Hello World: Koru is a Zig Superset

This test demonstrates the most fundamental property of Koru: **any valid Zig program is also a valid Koru program**.

## What You're Looking At

The `input.kz` file is pure, standard Zig code:

```zig
const std = @import("std");

pub fn main() void {
    std.debug.print("Hello World\n", .{});
}
```

There's nothing Koru-specific here at all. The Koru compiler sees this, recognizes it as valid Zig, and passes it through to Zig for compilation.

## Why This Matters

This isn't just a convenience feature—it's a core design principle:

1. **Zero Learning Curve for Zig Users** - Your existing Zig code works immediately. You can adopt Koru incrementally.

2. **No Runtime Overhead** - When you're not using Koru features, you get exactly the same binary Zig would produce.

3. **Gradual Enhancement** - Start with pure Zig, add events where they make sense, keep everything else unchanged.

## The Test

- **Input**: Standard Zig hello world
- **Expected**: `Hello World` printed to stderr
- **Proves**: The Koru compiler correctly handles pure Zig code

## What's Next

The next test introduces `~event` and `~proc`—the first Koru-specific syntax. You'll see how Koru extends Zig rather than replacing it.
