# Hello World: Koru and Its Host Language

Koru is a language in its own right. But it has something unusual: an exceptionally deep and intentional relationship with its host language — currently Zig.

## What You're Looking At

This `.kz` file contains no Koru at all. It is pure Zig:

```zig
const std = @import("std");

pub fn main() void {
    std.debug.print("Hello World\n", .{});
}
```

The Koru compiler sees this, recognizes it as host-language code, and passes it through unchanged.

## Why This Is Here

This isn't a compatibility shim or a migration path. It's a statement about how Koru is designed.

Koru and its host language are not in competition. Koru handles event-driven flow, continuation pipelines, comptime transforms, and type-safe branching. The host language handles everything else — memory layout, system calls, low-level data manipulation, expression evaluation. Together they cover the full stack without either one overreaching.

The boundary between them is intentional and deep. When you write `~proc`, the body is host-language code. When you write `~event`, the shape and branches are Koru. The two modes are always clear, always explicit, always composable.

## The Relationship Is Deep By Design

Koru could in principle run over other host languages. But the current design assumes a host that is:
- Systems-level (no GC, no hidden allocations)
- Expressive enough to implement Koru's stdlib procs
- Fast enough that Koru's zero-overhead model holds

Zig fits all of that. The tie is not accidental.

## What's Next

The next tests introduce `~event` and `~proc` — where Koru proper begins.
