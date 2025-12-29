# Control Flow & Expand Transforms

> Zero-cost abstractions through template expansion

## The `[expand]` Pattern

The `[expand]` annotation enables **template-based code generation** - define a pattern once, use it everywhere with zero runtime overhead.

### Why This Matters

Traditional approaches to stdlib wrappers require either:
- **Runtime dispatch** (slow)
- **Complex type systems** (hard)
- **Code generation tools** (external)

Koru's `[expand]` gives you **compile-time template expansion** with Zig's type inference for "free generics":

```koru
// 1. Define template - uses Zig's @TypeOf for type inference
~std.template:define(name: "sort") {
    std.mem.sort(@TypeOf(${arr}[0]), ${arr}, {}, std.sort.asc(@TypeOf(${arr}[0])));
}

// 2. Declare event - [norun] = no proc, [expand] = use template
~[norun|expand]pub event sort { arr: Expression }

// 3. Use it - clean syntax, optimal code
~sort(arr: my_array[0..])
```

The generated code is identical to hand-written Zig. No abstraction penalty.

### How It Works

1. **Parser** sees `[expand]` annotation on event declaration
2. **Transform pass** finds invocations matching the event
3. **Template lookup** finds the template by name
4. **Interpolation** substitutes `${placeholder}` with actual values
5. **Code emission** inlines the result - no function call overhead

### The "Free Generics" Trick

Zig's `@TypeOf` does the heavy lifting:

```zig
// Template doesn't know the type - Zig figures it out!
std.mem.sort(@TypeOf(${arr}[0]), ${arr}, {}, ...);
```

This works for `[]i32`, `[]f64`, `[]MyStruct` - any sortable slice. No Koru type parameters needed.

## Tests in This Category

| Test | Description |
|------|-------------|
| [320_050_expand_basic](320_050_expand_basic/) | Simplest case - debug print with Expression parameter |
| [320_051_expand_stdlib_wrap](320_051_expand_stdlib_wrap/) | Real-world pattern - wrapping `std.mem.sort` |

## Building the Stdlib

This pattern is the foundation for Koru's stdlib. Each wrapper follows the same recipe:

1. **Template** in `koru_std/template.kz` or inline
2. **Event** with `[norun|expand]` in the appropriate module
3. **Test** documenting usage in regression suite

See `koru_std/array.kz` for a work-in-progress example.

## Related

- [SPEC.md](../../../SPEC.md) - Main language specification
- [template.kz](../../../koru_std/template.kz) - Template system implementation
- [transform_pass_runner.zig](../../../src/transform_pass_runner.zig) - Expand transform logic
